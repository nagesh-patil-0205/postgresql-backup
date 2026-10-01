#!/bin/bash
# Run interactively on the backup server as the account that runs cron.
set +x
set -Eeuo pipefail
umask 077

for TOOL in gpg python3 mktemp flock; do
    command -v "$TOOL" >/dev/null || { echo "Missing command: $TOOL" >&2; exit 1; }
done

TARGET_ENV="${1:-}"
if [ -z "$TARGET_ENV" ]; then
    read -r -p 'Environment (dev/qat/pre/prod): ' TARGET_ENV
fi
case "$TARGET_ENV" in
    dev|qat|pre|prod) ;;
    *) echo 'Use dev, qat, pre, or prod. Existing Dev configuration is unchanged.' >&2; exit 1 ;;
esac

BASE_DIR="/opt/database/backup/env/$TARGET_ENV"
PUBLIC_KEY="$BASE_DIR/postgres-backup-public.asc"
KEY_HOME="$BASE_DIR/gnupg"
LAUNCHER="$BASE_DIR/run-backup.sh"

mkdir -p "$BASE_DIR"
exec 9> "$BASE_DIR/.encryption-setup.lock"
flock -n 9 || { echo 'Another setup is running for this environment.' >&2; exit 1; }
STAGING=$(mktemp -d "$BASE_DIR/.setup.XXXXXXXX")
cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 700 "$STAGING/gnupg"

# New installations generate their own environment-specific recovery key.
# Keep this durable directory on errors so retries never silently rotate keys.
RECOVERY_DIR="${RECOVERY_ROOT:-$HOME/postgres-backup-recovery}/$TARGET_ENV"
RECOVERY_HOME="$RECOVERY_DIR/gnupg"
PIN_FILE="$BASE_DIR/recipient.fingerprint"
if [ ! -s "$PUBLIC_KEY" ] && [ ! -s "$PIN_FILE" ] && [ ! -e "$LAUNCHER" ]; then
    # Do not replace a previously imported key just because its export is missing.
    if [ -d "$KEY_HOME" ]; then
        gpg --no-options --homedir "$KEY_HOME" --batch --with-colons --list-keys > "$STAGING/existing"
        if grep -q '^pub:' "$STAGING/existing"; then
            echo 'Existing backup key found. Export that key or restore its public export before retrying.' >&2
            exit 1
        fi
    fi
    install -d -m 700 "$RECOVERY_DIR" "$RECOVERY_HOME"
    export GPG_TTY="$(tty)"
    gpg --no-options --homedir "$RECOVERY_HOME" --batch --with-colons --list-keys > "$STAGING/recovery"
    if ! grep -q '^pub:' "$STAGING/recovery"; then
        echo "Creating a separate ${TARGET_ENV^^} recovery key. GPG will ask for a strong passphrase."
        gpg --no-options --homedir "$RECOVERY_HOME" --quick-generate-key \
            "PostgreSQL ${TARGET_ENV^^} Backup" rsa4096 cert 2y
    fi
    gpg --no-options --homedir "$RECOVERY_HOME" --batch --with-colons --list-secret-keys > "$STAGING/recovery"
    FINGERPRINT=$(python3 - "$STAGING/recovery" <<'PY'
import sys
keys = []
primary = False
for line in open(sys.argv[1]):
    fields = line.rstrip('\n').split(':')
    if fields[0] == 'sec':
        primary = True
    elif fields[0] == 'fpr' and primary:
        keys.append(fields[9])
        primary = False
if len(keys) != 1:
    sys.exit('Expected exactly one recovery private key; inspect the recovery directory.')
print(keys[0])
PY
)
    if ! awk -F: '$1 == "ssb" && $12 ~ /e/ {found=1} END {exit !found}' "$STAGING/recovery"; then
        gpg --no-options --homedir "$RECOVERY_HOME" --quick-add-key "$FINGERPRINT" rsa4096 encr 2y
    fi
    gpg --no-options --homedir "$RECOVERY_HOME" --armor --export "$FINGERPRINT" > "$STAGING/public.asc"
    # Export atomically: an interrupted passphrase prompt cannot leave a final empty export.
    gpg --no-options --homedir "$RECOVERY_HOME" --armor --export-secret-keys "$FINGERPRINT" \
        > "$RECOVERY_DIR/private-export.pending"
    test -s "$RECOVERY_DIR/private-export.pending"
    mv -- "$RECOVERY_DIR/private-export.pending" "$RECOVERY_DIR/postgres-backup-private.asc"
    install -m 600 "$STAGING/public.asc" "$RECOVERY_DIR/postgres-backup-public.asc"
    printf '%s\n' "$FINGERPRINT" > "$RECOVERY_DIR/fingerprint.txt"
elif [ -s "$PIN_FILE" ]; then
    FINGERPRINT=$(cat "$PIN_FILE")
else
    read -r -p 'Existing key: verified PRIMARY fingerprint (no spaces): ' FINGERPRINT
fi
if [[ ! "$FINGERPRINT" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
    echo 'Expected a full 40- or 64-character hexadecimal fingerprint.' >&2
    exit 1
fi
FINGERPRINT="${FINGERPRINT^^}"

if [ -s "$STAGING/public.asc" ]; then
    : # Generated above; its fingerprint is already known.
elif [ -s "$PUBLIC_KEY" ]; then
    cp -- "$PUBLIC_KEY" "$STAGING/public.asc"
else
    echo "Public export missing: $PUBLIC_KEY"
    echo 'Supply an existing public export, either a local absolute path or'
    echo 'an SCP source such as operator@recovery-host:/absolute/path/postgres-backup-public.asc'
    echo 'The recovery machine must be reachable by SSH for SCP. Do not supply a private export.'
    read -r -p 'Public-key source: ' KEY_SOURCE
    case "$KEY_SOURCE" in
        /*) cp -- "$KEY_SOURCE" "$STAGING/public.asc" ;;
        *:*) command -v scp >/dev/null || { echo 'Install scp first.' >&2; exit 1; }
             scp -- "$KEY_SOURCE" "$STAGING/public.asc" ;;
        *) echo 'Provide an absolute local path or an SCP source.' >&2; exit 1 ;;
    esac
fi

# Inspect in an isolated temporary keyring before installing anything.
gpg --no-options --homedir "$STAGING/gnupg" --batch --with-colons \
    --import-options show-only --import "$STAGING/public.asc" > "$STAGING/metadata"
python3 - "$FINGERPRINT" "$STAGING/metadata" <<'PY'
import sys
expected, path = sys.argv[1:]
fingerprints = []
primary = False
with open(path) as records:
    for record in records:
        fields = record.rstrip('\n').split(':')
        if fields[0] in ('sec', 'ssb'):
            sys.exit('Refusing a private-key export. Transfer only the public export.')
        if fields[0] == 'pub':
            primary = True
        elif fields[0] == 'fpr' and primary:
            fingerprints.append(fields[9].upper())
            primary = False
if fingerprints != [expected]:
    sys.exit('Public export must contain exactly the verified environment key.')
PY

# Prefer the deployed environment script; otherwise use backup.sh beside this file.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ ! -s "$BASE_DIR/backup.sh" ]; then
    if [ ! -s "$SCRIPT_DIR/backup.sh" ]; then
        echo "Place the updated backup.sh beside this setup script and retry." >&2
        exit 1
    fi
    install -m 700 "$SCRIPT_DIR/backup.sh" "$BASE_DIR/backup.sh"
fi

{
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'export ENV=%q\n' "$TARGET_ENV"
    printf 'export GPG_HOME=%q\n' "$KEY_HOME"
    printf 'export GPG_PUBLIC_KEY_FILE=%q\n' "$PUBLIC_KEY"
    printf 'export GPG_RECIPIENT=%q\n' "$FINGERPRINT"
    printf 'export WORK_DIR=%q\n' "/var/tmp/postgresql-refresh/$TARGET_ENV"
    printf 'export LOG_DIR=%q\n' "/var/log/postgresql-refresh/$TARGET_ENV"
    printf 'exec /bin/bash %q\n' "$BASE_DIR/backup.sh"
} > "$STAGING/run-backup.sh"

if [ -e "$LAUNCHER" ] && ! cmp -s "$STAGING/run-backup.sh" "$LAUNCHER"; then
    echo "Existing launcher differs: $LAUNCHER. Inspect it before changing configuration." >&2
    exit 1
fi

install -d -m 700 "$KEY_HOME"
gpg --no-options --homedir "$KEY_HOME" --batch --import "$STAGING/public.asc"
install -m 600 "$STAGING/public.asc" "$PUBLIC_KEY"
install -m 700 "$STAGING/run-backup.sh" "$LAUNCHER"
printf '%s\n' "$FINGERPRINT" > "$PIN_FILE"
chmod 600 "$PIN_FILE"

echo "Setup complete for $TARGET_ENV. Check REGION, S3_BUCKET and KMS_KEY_ID in $BASE_DIR/backup.sh."
echo "GPG_RECIPIENT=$FINGERPRINT"
if [ -d "$RECOVERY_DIR" ]; then
    echo "Recovery material: $RECOVERY_DIR"
    echo 'Back up this entire directory to protected offline storage; keep the passphrase separately.'
    echo 'Private recovery keys remain on this server. After verifying an offline copy and a restore,'
    echo 'move recovery material off the backup server. The backup gnupg directory has only the public key.'
    echo 'Keys expire after two years; renew or rotate before expiration.'
fi
echo 'Run a backup:'
printf '/bin/bash %q\n' "$LAUNCHER"
echo 'After a successful backup, add this to crontab -e (17:00 server time):'
printf '0 17 * * * /bin/bash %s\n' "$LAUNCHER"
