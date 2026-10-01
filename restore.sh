#!/bin/bash

set +x
set -Eeuo pipefail

# Restore settings; configure each server copy for its intended environment.
ENV="${1:-${ENV:-< REPLACE_WITH_ENVIRONMENT >}}"
REGION="${REGION:-us-east-1}"
SECRET_ID="${SECRET_ID:-alias/bpobox/${ENV}/python/secret/key}"
S3_BUCKET="${S3_BUCKET:-< REPLACE_WITH_S3_BUCKET_NAME >}"
KMS_KEY_ID="${KMS_KEY_ID:-< REPLACE_WITH_KMS_KEY_ARN >}"
WORK_DIR="${WORK_DIR:-/var/tmp/postgresql-restore/${ENV}}"
LOG_DIR="${LOG_DIR:-/var/log/postgresql-refresh/${ENV}}"
GPG_HOME="${GPG_HOME:-/opt/database/backup/env/${ENV}/gnupg}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-Admin@2026}"
GPG_PRIVATE_KEY_FILE="${GPG_PRIVATE_KEY_FILE:-/root/postgres-backup-recovery/${ENV}/postgres-backup-private.asc}"
RECOVERY_DIR="${RECOVERY_ROOT:-$HOME/postgres-backup-recovery}/${ENV}"

# Keep the configured script private (chmod 700). Do not export the passphrase.
# For a literal passphrase with shell metacharacters, use a single-quoted
# assignment instead: GPG_PASSPHRASE='your actual passphrase'.
export -n GPG_PASSPHRASE

# Connect to the existing database; create a separate new database for restore.
if [ "$#" -gt 1 ]; then
    echo 'Usage: bash restore.sh [dev|qat|pre|prod]' >&2
    exit 1
fi
case "$ENV" in
    dev|qat|pre|prod) ;;
    *) echo 'Choose dev, qat, pre, or prod.' >&2; exit 1 ;;
esac
if [ -z "$KMS_KEY_ID" ] || [ "$KMS_KEY_ID" = REPLACE_WITH_KMS_KEY_ARN ]; then
    echo 'Set KMS_KEY_ID at the top of restore.sh before running.' >&2
    exit 1
fi
if [ -z "${GPG_HOME:-}" ]; then
    if [ -d "$RECOVERY_DIR/gnupg" ]; then
        GPG_HOME="$RECOVERY_DIR/gnupg"
    else
        # Supports existing restore installations and recovery on a new server.
        GPG_HOME="/opt/database/restore/env/${ENV}/gnupg"
    fi
fi

JOB=restore
POSTGRES_TOOL=psql

# --------------------------------------------------
# Start a local log before checking prerequisites; remove after successful upload
# --------------------------------------------------

umask 077
TIMESTAMP=$(date -u '+%Y%m%d-%H%M%S')
YEAR=${TIMESTAMP:0:4}
MONTH=${TIMESTAMP:4:2}
DAY=${TIMESTAMP:6:2}
mkdir -p "$LOG_DIR"
LOG_FILE=$(mktemp "${LOG_DIR}/${JOB}-${TIMESTAMP}.XXXXXXXXXX.log")
RUN_ID=${LOG_FILE##*/}
RUN_ID=${RUN_ID%.log}
LOG_S3_URI="s3://${S3_BUCKET}/Database/${YEAR}/${MONTH}/${DAY}/${ENV^}/${RUN_ID}.log"
RUN_DIR=""
DUMP_FILE=""
SHA_FILE=""
ENCRYPTED_FILE=""
STAGE="STARTUP"
NEW_DATABASE_CREATED=0

# Direct file redirection keeps output synchronous, including command errors.
# Keep the original descriptors for cron's final summary/email.
exec 3>&1 4>&2
exec >> "$LOG_FILE" 2>&1

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

finish() {
    EXIT_CODE=$?
    trap - EXIT ERR INT TERM HUP
    set +e

    # Remove this run's temporary files before uploading its log.
    if [ -n "$RUN_DIR" ]; then
        rm -f -- "$RUN_DIR/pgpass" "$RUN_DIR/objects.json" "$RUN_DIR/keys.txt" "${DUMP_FILE:-}" "${SHA_FILE:-}" "${ENCRYPTED_FILE:-}"
        CLEANUP_CODE=$?
        rmdir -- "$RUN_DIR"
        DIRECTORY_CODE=$?
        if [ "$CLEANUP_CODE" -ne 0 ] || [ "$DIRECTORY_CODE" -ne 0 ]; then
            log "ERROR|STAGE=CLEANUP|Temporary files could not all be removed"
            if [ "$EXIT_CODE" -eq 0 ]; then EXIT_CODE=1; fi
        fi
    fi

    if [ "$EXIT_CODE" -eq 0 ]; then
        log "${JOB^^}_SUCCESS|EXIT_CODE=0"
    else
        log "${JOB^^}_FAILED|STAGE=${STAGE}|EXIT_CODE=${EXIT_CODE}"
        if [ "$NEW_DATABASE_CREATED" -eq 1 ]; then
            log "NEW_DATABASE_RETAINED|DATABASE=${NEW_DATABASE}|Inspect before retrying; it is not automatically dropped"
        fi
    fi
    log "LOG_UPLOAD_PENDING|S3_URI=${LOG_S3_URI}"

    # Stop writing to the file while AWS reads it. Upload diagnostics go to
    # a separate file, then are appended locally if all retries fail.
    exec 1>&3 2>&4
    UPLOAD_OK=0
    for ATTEMPT in 1 2 3; do
        if aws s3 cp "$LOG_FILE" "$LOG_S3_URI" \
            --region "$REGION" \
            --sse aws:kms \
            --sse-kms-key-id "$KMS_KEY_ID" \
            --checksum-algorithm SHA256 \
            --content-type "text/plain" \
            --only-show-errors > "${LOG_FILE}.upload-error" 2>&1; then
            UPLOAD_OK=1
            break
        fi
        if [ "$ATTEMPT" -lt 3 ]; then sleep 5; fi
    done

    if [ "$UPLOAD_OK" -eq 1 ]; then
        # The uploaded log already contains the final job status.
        log "LOG_UPLOAD_SUCCESS|S3_URI=${LOG_S3_URI}"
        if ! rm -f -- "$LOG_FILE" "${LOG_FILE}.upload-error"; then
            printf 'ERROR: Log uploaded, but local log cleanup failed: %s\n' "$LOG_FILE" >&2
            if [ "$EXIT_CODE" -eq 0 ]; then EXIT_CODE=1; fi
        fi
        printf '%s finished (exit %s). Log: %s\n' "$JOB" "$EXIT_CODE" "$LOG_S3_URI"
    else
        log "LOG_UPLOAD_FAILED|Local log retained: ${LOG_FILE}" 2>> "$LOG_FILE"
        cat "${LOG_FILE}.upload-error" >> "$LOG_FILE"
        printf 'ERROR: %s log could not be uploaded. Local log: %s\n' "$JOB" "$LOG_FILE" >&2
        if [ "$EXIT_CODE" -eq 0 ]; then EXIT_CODE=74; fi
    fi
    exit "$EXIT_CODE"
}

trap finish EXIT
# Never log BASH_COMMAND: a failing command may contain a secret.
trap 'ERROR_CODE=$?; if [ "$BASH_SUBSHELL" -eq 0 ]; then log "ERROR|STAGE=${STAGE}|LINE=${LINENO}|EXIT_CODE=${ERROR_CODE}"; fi' ERR
trap 'log "INTERRUPTED|SIGNAL=INT"; exit 130' INT
trap 'log "INTERRUPTED|SIGNAL=TERM"; exit 143' TERM
trap 'log "INTERRUPTED|SIGNAL=HUP"; exit 129' HUP

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=3

log "${JOB^^}_STARTED|RUN_ID=${RUN_ID}"
log "LOG_DESTINATION|S3_URI=${LOG_S3_URI}"

# --------------------------------------------------
# Check tools and prevent overlapping cron runs
# --------------------------------------------------

STAGE="PREREQUISITES"
for TOOL in aws python3 sha256sum mktemp flock "$POSTGRES_TOOL"; do
    command -v "$TOOL" >/dev/null 2>&1 || {
        log "ERROR|Required command not found: $TOOL"
        exit 1
    }
done

if [ "$KMS_KEY_ID" = "REPLACE_WITH_KMS_KEY_ARN" ]; then
    log "ERROR|Set KMS_KEY_ID to your S3 encryption key ARN"
    exit 1
fi

mkdir -p "$WORK_DIR"
exec 9> "$WORK_DIR/${JOB}.lock"
if ! flock -n 9; then
    log "ERROR|Another ${JOB} job is already running"
    exit 75
fi
RUN_DIR=$(mktemp -d "${WORK_DIR}/run.XXXXXXXXXX")

# Require encryption without configuring a CA certificate file.
export PGSSLMODE=require
unset PGSSLROOTCERT
export PGCONNECT_TIMEOUT=15
unset PGPASSWORD PGSERVICE PGSERVICEFILE PGHOSTADDR PGOPTIONS DB_PASSWORD SECRET_JSON DATABASE_CONFIG PSQL_BACKUP_URL

# --------------------------------------------------
# Ask for backup year/month/day and a NEW database name
# --------------------------------------------------

STAGE="INPUT"
prompt() {
    printf '%s' "$2" >&3
    if ! IFS= read -r "$1"; then
        log "ERROR|Input ended; run restore.sh interactively"
        exit 1
    fi
}

prompt BACKUP_YEAR 'Backup year (YYYY): '
prompt BACKUP_MONTH 'Backup month (1-12): '
prompt BACKUP_DAY 'Backup day (1-31): '

BACKUP_DATE=$(python3 -c '
import datetime, re, sys
try:
    year, month, day = sys.argv[1:]
    if not re.fullmatch(r"[0-9]{4}", year) or not all(re.fullmatch(r"[0-9]{1,2}", x) for x in (month, day)):
        raise ValueError()
    date = datetime.date(int(year), int(month), int(day))
    print(f"{date.year:04d}/{date.month:02d}/{date.day:02d}")
except ValueError:
    sys.exit("ERROR: Enter a valid calendar date.")
' "$BACKUP_YEAR" "$BACKUP_MONTH" "$BACKUP_DAY")

S3_PREFIX="Database/${BACKUP_DATE}/${ENV^}"
LOG_S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/${RUN_ID}.log"
log "SELECTED_BACKUP_FOLDER|s3://${S3_BUCKET}/${S3_PREFIX}/"

# BEGIN DATABASE NAME INPUT
while true; do
    prompt NEW_DATABASE 'New database name (for example qat_restore_20261001; q to cancel): '
    NEW_DATABASE="${NEW_DATABASE#"${NEW_DATABASE%%[![:space:]]*}"}"
    NEW_DATABASE="${NEW_DATABASE%"${NEW_DATABASE##*[![:space:]]}"}"
    if [[ "$NEW_DATABASE" == q || "$NEW_DATABASE" == Q ]]; then
        log "RESTORE_CANCELLED|No database was created"
        exit 130
    fi
    # psql quotes the name as an SQL identifier when creating the database.
    if [[ "$NEW_DATABASE" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,62}$ ]]; then
        break
    fi
    printf 'Invalid name. Use 1-63 ASCII letters, digits, underscores or hyphens; start with a letter or underscore. Example: qat_restore_20261001.\n' >&3
    log "DATABASE_NAME_RETRY|Invalid database name; waiting for another name"
done
# END DATABASE NAME INPUT

# --------------------------------------------------
# List backups in the selected folder and choose one
# --------------------------------------------------

STAGE="LIST_BACKUPS"
aws s3api list-objects-v2 --bucket "$S3_BUCKET" \
    --prefix "${S3_PREFIX}/" --region "$REGION" \
    --output json > "$RUN_DIR/objects.json"

# AWS CLI automatically paginates. Offer only the selected environment's
# SQL files with SHA companions, including legacy unencrypted SQL files.
python3 -c '
import json, sys
objects = json.load(open(sys.argv[1], encoding="utf-8")).get("Contents") or []
keys = {item["Key"] for item in objects}
prefix = sys.argv[2] + "/"
for key in sorted(keys):
    name = key[len(prefix):]
    if key.startswith(prefix) and name.endswith((".sql", ".sql.gpg")) and key + ".sha256" in keys:
        if not any(ord(c) < 32 or ord(c) == 127 for c in key):
            sys.stdout.buffer.write((key + "\n").encode("utf-8"))
' "$RUN_DIR/objects.json" "$S3_PREFIX" > "$RUN_DIR/keys.txt"
mapfile -t BACKUP_KEYS < "$RUN_DIR/keys.txt"

if [ "${#BACKUP_KEYS[@]}" -eq 0 ]; then
    log "ERROR|No SQL backups with SHA256 files found in the selected folder"
    exit 1
fi

printf '\nAvailable backups:\n' >&3
for INDEX in "${!BACKUP_KEYS[@]}"; do
    printf '  %s) %s\n' "$((INDEX + 1))" "${BACKUP_KEYS[$INDEX]#"$S3_PREFIX/"}" >&3
done
STAGE="SELECT_BACKUP"
while true; do
    if [ "${#BACKUP_KEYS[@]}" -eq 1 ]; then
        prompt SELECTION 'Enter 1, a filename, or press Enter for the only backup (q to cancel): '
    else
        prompt SELECTION "Enter a backup number (1-${#BACKUP_KEYS[@]}) or filename (q to cancel): "
    fi
    # Accept pasted values with surrounding spaces, tabs or a Windows CR.
    SELECTION="${SELECTION#"${SELECTION%%[![:space:]]*}"}"
    SELECTION="${SELECTION%"${SELECTION##*[![:space:]]}"}"
    if [[ "$SELECTION" == q || "$SELECTION" == Q ]]; then
        log "RESTORE_CANCELLED|No database was created"
        exit 130
    fi
    if [ -z "$SELECTION" ] && [ "${#BACKUP_KEYS[@]}" -eq 1 ]; then
        SELECTION=1
    fi

    MATCHED_INDEX=-1
    if [[ "$SELECTION" =~ ^[0-9]{1,9}$ ]]; then
        # Explicit decimal conversion also accepts values such as 01.
        NUMBER=$((10#$SELECTION))
        if [ "$NUMBER" -ge 1 ] && [ "$NUMBER" -le "${#BACKUP_KEYS[@]}" ]; then
            MATCHED_INDEX=$((NUMBER - 1))
        fi
    else
        MATCH_COUNT=0
        for INDEX in "${!BACKUP_KEYS[@]}"; do
            KEY=${BACKUP_KEYS[$INDEX]}
            if [[ "$SELECTION" == "$KEY" ||
                  "$SELECTION" == "${KEY#"$S3_PREFIX/"}" ||
                  "$SELECTION" == "s3://${S3_BUCKET}/${KEY}" ||
                  "$SELECTION" == "${KEY##*/}" ]]; then
                MATCHED_INDEX=$INDEX
                MATCH_COUNT=$((MATCH_COUNT + 1))
            fi
        done
        # Identical basenames in different subfolders need an explicit choice.
        if [ "$MATCH_COUNT" -ne 1 ]; then MATCHED_INDEX=-1; fi
    fi

    if [ "$MATCHED_INDEX" -ge 0 ]; then break; fi
    printf 'Selection not recognized or ambiguous. Enter a listed number (for example 1) or the displayed path.\n' >&3
    log "SELECTION_RETRY|Selection did not identify exactly one listed backup"
done
S3_URI="s3://${S3_BUCKET}/${BACKUP_KEYS[$MATCHED_INDEX]}"
log "BACKUP_SELECTED|S3_URI=${S3_URI}"
LOG_S3_URI="${S3_URI%/*}/${RUN_ID}.log"

FILE_NAME="${S3_URI##*/}"
DUMP_FILE="$RUN_DIR/backup.sql"
SHA_FILE="$RUN_DIR/backup.sql.sha256"

STAGE="DOWNLOAD_BACKUP"
log "Downloading SQL dump and checksum from ${S3_URI}"
aws s3 cp "$S3_URI" "$DUMP_FILE" \
    --region "$REGION" \
    --checksum-mode ENABLED \
    --only-show-errors

aws s3 cp "${S3_URI}.sha256" "$SHA_FILE" \
    --region "$REGION" \
    --checksum-mode ENABLED \
    --only-show-errors

# --------------------------------------------------
# Validate SHA256 BEFORE connecting to PostgreSQL
# --------------------------------------------------

STAGE="CHECKSUM"
SHA256=$(sha256sum "$DUMP_FILE" | awk '{print $1}')
EXPECTED_LINE=$(cat "$SHA_FILE")

if [ ! -s "$DUMP_FILE" ] || [ "$EXPECTED_LINE" != "$SHA256  $FILE_NAME" ]; then
    log "ERROR|Empty dump or SHA256 mismatch; restore stopped"
    exit 10
fi
log "SHA256_VALIDATION_COMPLETED"

# Finish decryption and integrity validation before any database connection.
# Do not pipe into psql: GPG can report damaged ciphertext only at end-of-file.
if [[ "$FILE_NAME" == *.sql.gpg ]]; then
    STAGE="DECRYPT_BACKUP"
    if [ -z "$GPG_PASSPHRASE" ] || [ "$GPG_PASSPHRASE" = REPLACE_WITH_PRIVATE_KEY_PASSPHRASE ] ||
        [[ "$GPG_PASSPHRASE" == *$'\n'* || "$GPG_PASSPHRASE" == *$'\r'* ]]; then
        printf 'Set GPG_PASSPHRASE at the top of restore.sh to the private key\x27s single-line passphrase.\n' >&3
        log "ERROR|Private-key passphrase is not configured; restore stopped"
        exit 1
    fi
    command -v gpg >/dev/null 2>&1 || {
        log "ERROR|Required command not found: gpg"
        exit 1
    }
    if [ -n "$GPG_PRIVATE_KEY_FILE" ]; then
        if [ ! -r "$GPG_PRIVATE_KEY_FILE" ]; then
            log "ERROR|Private-key export is not readable: $GPG_PRIVATE_KEY_FILE"
            exit 1
        fi
        mkdir -p -- "$GPG_HOME"
        chmod 700 -- "$GPG_HOME"
        gpg --no-options --homedir "$GPG_HOME" --batch --pinentry-mode loopback \
            --passphrase-fd 5 --import "$GPG_PRIVATE_KEY_FILE" 5<<< "$GPG_PASSPHRASE"
    fi
    if [ ! -d "$GPG_HOME" ]; then
        printf 'Recovery keyring missing: %s\nSet GPG_HOME to the recovery keyring, or GPG_PRIVATE_KEY_FILE to the protected private export.\n' "$GPG_HOME" >&3
        log "ERROR|Recovery keyring missing; the backup public key cannot decrypt backups"
        exit 1
    fi
    # Do not require today's recipient fingerprint: old backups can use retired keys.
    if ! gpg --no-options --homedir "$GPG_HOME" --batch --with-colons --list-secret-keys |
        awk -F: '$1 == "sec" {found=1} END {exit !found}'; then
        printf 'No private recovery key found in %s. Set GPG_HOME or GPG_PRIVATE_KEY_FILE.\n' "$GPG_HOME" >&3
        log "ERROR|No private recovery key available; restore stopped before database access"
        exit 1
    fi
    ENCRYPTED_FILE="$RUN_DIR/backup.sql.gpg"
    mv -- "$DUMP_FILE" "$ENCRYPTED_FILE"
    printf 'Decrypting backup using the configured private-key passphrase.\n' >&3
    # Pass the value through a private descriptor, never a process argument.
    if ! gpg --no-options --homedir "$GPG_HOME" --batch --pinentry-mode loopback \
        --passphrase-fd 5 --output "$DUMP_FILE" \
        --decrypt "$ENCRYPTED_FILE" 5<<< "$GPG_PASSPHRASE"; then
        printf 'Decryption failed. Use the private key that encrypted this backup and its passphrase. See the restore log.\n' >&3
        log "ERROR|Decryption failed; no database was created"
        exit 1
    fi
    if [ ! -s "$DUMP_FILE" ]; then
        log "ERROR|Decrypted SQL dump is empty; restore stopped"
        exit 10
    fi
    log "DECRYPTION_COMPLETED"
fi
unset GPG_PASSPHRASE

# --------------------------------------------------
# Get PSQL_BACKUP_URL from Secrets Manager
# --------------------------------------------------

STAGE="GET_SECRET"
log "Fetching PSQL_BACKUP_URL from Secrets Manager"

SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region "$REGION" \
    --query SecretString \
    --output text)

# Parse once into separate fields. Never pass the URL as a command argument.
# Percent-encoded characters in usernames/passwords/database names are decoded.
DATABASE_CONFIG=$(python3 -c '
import json, re, sys
from urllib.parse import urlsplit, unquote, parse_qsl
try:
    raw = json.loads(sys.stdin.read())["PSQL_BACKUP_URL"]
    if not isinstance(raw, str) or any(ord(c) < 33 for c in raw):
        raise ValueError()
    if re.search(r"%(?![0-9A-Fa-f]{2})", raw):
        raise ValueError()
    url = urlsplit(raw)
    # SQLAlchemy/asyncpg URLs contain a driver suffix; libpq uses the parsed fields.
    if url.scheme not in ("postgres", "postgresql", "postgresql+asyncpg") or url.fragment:
        raise ValueError()
    port = url.port if url.port is not None else 5432
    fields = {
        "host": unquote(url.hostname or "", errors="strict"),
        "port": port,
        "username": unquote(url.username or "", errors="strict"),
        "password": unquote(url.password or "", errors="strict"),
        "database": unquote(url.path[1:], errors="strict") if url.path.startswith("/") else ""
    }
    for key in ("host", "username", "password", "database"):
        if not fields[key] or any(ord(c) < 32 or ord(c) == 127 for c in fields[key]):
            raise ValueError()
    if not 1 <= port <= 65535 or any(c in fields["host"] for c in ",/ "):
        raise ValueError()
    # Only a single TCP host is supported. Do not silently discard connection options.
    seen = set()
    for key, value in parse_qsl(url.query, keep_blank_values=True, strict_parsing=True):
        if key in seen or key not in ("sslmode", "schema"):
            raise ValueError()
        seen.add(key)
        if key == "sslmode" and value != "require":
            raise ValueError()
        # schema is an application option; this backup includes the entire database.
    print(json.dumps(fields))
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit("ERROR: Invalid PSQL_BACKUP_URL. Use postgres://, postgresql:// or postgresql+asyncpg://user:password@host[:port]/database; optional sslmode=require and schema only.")
' <<< "$SECRET_JSON")

DB_HOST=$(python3 -c \
    'import json,sys; print(json.loads(sys.stdin.read())["host"])' \
    <<< "$DATABASE_CONFIG")
DB_PORT=$(python3 -c \
    'import json,sys; print(json.loads(sys.stdin.read())["port"])' \
    <<< "$DATABASE_CONFIG")
DB_USER=$(python3 -c \
    'import json,sys; print(json.loads(sys.stdin.read())["username"])' \
    <<< "$DATABASE_CONFIG")
DB_PASSWORD=$(python3 -c \
    'import json,sys; print(json.loads(sys.stdin.read())["password"])' \
    <<< "$DATABASE_CONFIG")
DATABASE=$(python3 -c \
    'import json,sys; print(json.loads(sys.stdin.read())["database"])' \
    <<< "$DATABASE_CONFIG")

# --------------------------------------------------
# Create temporary PostgreSQL credential file
# --------------------------------------------------

CONFIG_FILE="$RUN_DIR/pgpass"
DB_PASSWORD=${DB_PASSWORD//\\/\\\\}
DB_PASSWORD=${DB_PASSWORD//:/\\:}
printf '*:*:*:*:%s\n' "$DB_PASSWORD" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

unset DB_PASSWORD SECRET_JSON DATABASE_CONFIG PSQL_BACKUP_URL
export PGPASSFILE="$CONFIG_FILE"
export PGHOST="$DB_HOST"
export PGPORT="$DB_PORT"
export PGUSER="$DB_USER"
export PGDATABASE="$DATABASE"
log "Database connection settings loaded"

# --------------------------------------------------
# Check the name and privileges without changing existing data
# --------------------------------------------------

STAGE="CHECK_NEW_DATABASE"
if [ "$NEW_DATABASE" = "$DATABASE" ]; then
    log "ERROR|Choose a different name; the database in PSQL_BACKUP_URL is preserved"
    exit 1
fi

# psql quotes these variables as SQL literals; do not interpolate shell SQL.
DATABASE_CHECK=$(psql --no-psqlrc --no-password --tuples-only --no-align \
    --set=ON_ERROR_STOP=1 --set=new_database="$NEW_DATABASE" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'new_database'),
       rolcreatedb OR rolsuper
FROM pg_roles WHERE rolname = current_user;
SQL
)
case "$DATABASE_CHECK" in
    f\|t) ;;
    t\|*) log "ERROR|Database already exists; nothing will be overwritten"; exit 1 ;;
    f\|f) log "ERROR|The PSQL_BACKUP_URL user needs CREATEDB; ask your DBA to provide an authorized role"; exit 1 ;;
    *) log "ERROR|Could not verify database name and creation privileges"; exit 1 ;;
esac

# --------------------------------------------------
# Create a fresh database owned by the existing login user
# --------------------------------------------------

STAGE="CREATE_DATABASE"
printf '\nCreating %s on %s, owned by existing user %s.\n' "$NEW_DATABASE" "$DB_HOST" "$DB_USER" >&3
log "CREATE_DATABASE|DATABASE=${NEW_DATABASE}|OWNER=${DB_USER}"

# CREATE DATABASE must run outside the restore transaction. If another session
# creates this name after the check, this statement fails and restore stops.
psql --no-psqlrc --no-password --set=ON_ERROR_STOP=1 \
    --set=new_database="$NEW_DATABASE" --set=owner="$DB_USER" <<'SQL'
CREATE DATABASE :"new_database" WITH OWNER = :"owner" TEMPLATE = template0;
SQL
NEW_DATABASE_CREATED=1

# --------------------------------------------------
# Restore only into the NEW database
# --------------------------------------------------

# Our backup uses --no-owner --no-acl: restored objects belong to this login.
# This maps the existing user to the new database through ownership. It does
# not clone grants for other roles or change the user's server-wide privileges.
export PGDATABASE="$NEW_DATABASE"
STAGE="DATABASE_RESTORE"
log "Restoring ${S3_URI} into ${NEW_DATABASE}"

# Only use trusted dumps made by backup.sh (no CREATE DATABASE / reconnect).
psql --no-psqlrc --no-password --quiet \
    --set=ON_ERROR_STOP=1 --set=VERBOSITY=terse \
    --single-transaction --file="$DUMP_FILE"

SIZE=$(wc -c < "$DUMP_FILE" | tr -d '[:space:]')
STAGE="COMPLETED"
log "RESTORE_COMPLETED|DATABASE=${NEW_DATABASE}|OWNER=${DB_USER}|S3_URI=${S3_URI}|SHA256=${SHA256}|SIZE=${SIZE}"
printf 'Restore completed: %s. Existing database %s was preserved.\n' "$NEW_DATABASE" "$DATABASE" >&3
# On failure, retain the new database for inspection; never drop any database.
