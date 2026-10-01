#!/bin/bash
# Create the deployment folders and placeholder scripts; preserve existing files.
set -Eeuo pipefail
umask 077

usage() {
    cat <<'HELP'
Usage: bash setup.sh [dev qat pre prod | all]

Examples:
  bash setup.sh dev qat     # Shared Dev/QAT server
  bash setup.sh pre         # Pre server
  bash setup.sh prod        # Prod server
  bash setup.sh all         # All four environments

Without arguments, prompts for space-separated environments.
Creates private folders and placeholder scripts under /opt/database.
Existing script contents are preserved. No backups, key generation or cron
changes are performed. DATABASE_BASE_DIR overrides /opt/database if needed.
HELP
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    usage
    exit 0
fi

if [ "$#" -eq 0 ]; then
    read -r -p 'Environments to prepare (for example dev qat, or all): ' ANSWER
    read -r -a ENVIRONMENTS <<< "$ANSWER"
else
    ENVIRONMENTS=("$@")
fi
if [ "${#ENVIRONMENTS[@]}" -eq 1 ] && [ "${ENVIRONMENTS[0]}" = all ]; then
    ENVIRONMENTS=(dev qat pre prod)
fi
if [ "${#ENVIRONMENTS[@]}" -eq 0 ]; then
    echo 'Select at least one environment.' >&2
    exit 1
fi

# Validate the entire request before creating any directories.
for TARGET_ENV in "${ENVIRONMENTS[@]}"; do
    case "$TARGET_ENV" in
        dev|qat|pre|prod) ;;
        *) printf 'Invalid environment: %s. Choose dev, qat, pre, prod or all.\n' "$TARGET_ENV" >&2; exit 1 ;;
    esac
done

BASE_DIR="${DATABASE_BASE_DIR:-/opt/database}"
if [[ "$BASE_DIR" != /* || "$BASE_DIR" = / ]]; then
    echo 'DATABASE_BASE_DIR must be an absolute directory other than /.' >&2
    exit 1
fi
BASE_DIR="${BASE_DIR%/}"

prepare_script() {
    local destination="$1"
    local directory="${destination%/*}"
    mkdir -p -- "$directory"
    chmod 700 -- "$directory"
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
        printf 'Refusing a symlink or non-regular script: %s\n' "$destination" >&2
        exit 1
    fi
    if [ -e "$destination" ]; then
        printf 'PRESERVED %s\n' "$destination"
    else
        # A placeholder must fail clearly if accidentally scheduled before deployment.
        (set -o noclobber; cat > "$destination" <<'PLACEHOLDER'
#!/bin/bash
echo "Setup placeholder: deploy and configure the actual script at $0 before running." >&2
exit 1
PLACEHOLDER
        )
        printf 'CREATED   %s\n' "$destination"
    fi
    chmod 700 -- "$destination"
}

declare -A PREPARED=()
for TARGET_ENV in "${ENVIRONMENTS[@]}"; do
    [ -z "${PREPARED[$TARGET_ENV]:-}" ] || continue
    prepare_script "$BASE_DIR/backup/env/$TARGET_ENV/backup.sh"
    prepare_script "$BASE_DIR/restore/env/$TARGET_ENV/restore.sh"
    PREPARED[$TARGET_ENV]=1
done
prepare_script "$BASE_DIR/encryption/encryption.sh"

printf '\nFolder setup complete. Existing script contents were preserved.\n'
printf 'Replace new placeholders with the real scripts and configure each environment.\n'
printf 'Then run encryption.sh for each environment and test its generated run-backup.sh.\n'
printf 'Schedule backups only after successful testing.\n'
