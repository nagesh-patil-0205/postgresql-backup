#!/bin/bash

set +x
set -Eeuo pipefail

# Source database settings for the cron backup job.
ENV="${ENV:-< REPLACE_WITH_ENVIRONMENT >}"
REGION="${REGION:-us-east-1}"
SECRET_ID="${SECRET_ID:-alias/bpobox/${ENV}/python/secret/key}"
S3_BUCKET="${S3_BUCKET:-< REPLACE_WITH_S3_BUCKET_NAME >}"
KMS_KEY_ID="${KMS_KEY_ID:-< REPLACE_WITH_KMS_KEY_ARN >}"
WORK_DIR="${WORK_DIR:-/var/tmp/postgresql-refresh}"
LOG_DIR="${LOG_DIR:-/var/log/postgresql-refresh}"
GPG_HOME="${GPG_HOME:-/opt/database/backup/env/${ENV}/gnupg}"
GPG_RECIPIENT="${GPG_RECIPIENT:-< REPLACE_WITH_GPG_RECIPIENT >}"
GPG_PUBLIC_KEY_FILE="${GPG_PUBLIC_KEY_FILE:-/opt/database/backup/env/${ENV}/postgres-backup-public.asc}"

JOB=backup
POSTGRES_TOOL=pg_dump

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
# Set the shared folder before secret retrieval so early failures go here too.
# Capitalize the environment folder to preserve the existing Pre backup path.
S3_PREFIX="Database/${YEAR}/${MONTH}/${DAY}/${ENV^}"
LOG_S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/${RUN_ID}.log"
RUN_DIR=""
DUMP_FILE=""
SHA_FILE=""
STAGE="STARTUP"

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
        rm -f -- "$RUN_DIR/pgpass" "${DUMP_FILE:-}" "${SHA_FILE:-}"
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
for TOOL in aws python3 sha256sum mktemp flock gpg "$POSTGRES_TOOL"; do
    command -v "$TOOL" >/dev/null 2>&1 || {
        log "ERROR|Required command not found: $TOOL"
        exit 1
    }
done

# Pin the verified full fingerprint, never an ambiguous name or email address.
if [[ ! "$GPG_RECIPIENT" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
    log "ERROR|Set GPG_RECIPIENT to the full public-key fingerprint (see ENCRYPTION.md)"
    exit 1
fi
mkdir -p -- "$GPG_HOME"
chmod 700 -- "$GPG_HOME"
if gpg --no-options --homedir "$GPG_HOME" --batch --list-keys "$GPG_RECIPIENT" > /dev/null 2>&1; then
    log "GPG_KEY_READY|Using configured public key"
else
    if [ ! -r "$GPG_PUBLIC_KEY_FILE" ]; then
        log "ERROR|Public key missing. Copy the recovery public-key export to $GPG_PUBLIC_KEY_FILE (or set GPG_PUBLIC_KEY_FILE). See ENCRYPTION.md for first-time key generation."
        exit 1
    fi
    # Inspect before importing: require the pinned primary fingerprint and public keys only.
    KEY_METADATA=$(gpg --no-options --homedir "$GPG_HOME" --batch \
        --with-colons --import-options show-only --import "$GPG_PUBLIC_KEY_FILE")
    if ! printf '%s\n' "$KEY_METADATA" | python3 -c '
import sys
expected = sys.argv[1].upper()
records = [line.split(":") for line in sys.stdin.read().splitlines()]
fingerprints = []
primary = False
for fields in records:
    if fields[0] in ("sec", "ssb"):
        sys.exit(1)
    if fields[0] == "pub":
        primary = True
    elif fields[0] == "fpr" and primary:
        fingerprints.append(fields[9].upper())
        primary = False
sys.exit(0 if fingerprints == [expected] else 1)
' "$GPG_RECIPIENT"; then
        log "ERROR|Public-key file must contain only the configured public key with its verified primary fingerprint"
        exit 1
    fi
    gpg --no-options --homedir "$GPG_HOME" --batch --import "$GPG_PUBLIC_KEY_FILE"
    gpg --no-options --homedir "$GPG_HOME" --batch --list-keys "$GPG_RECIPIENT" > /dev/null
    unset KEY_METADATA
    log "GPG_KEY_IMPORTED|Configured public key is ready for subsequent runs"
fi

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
# File names and date-based S3 path (UTC)
# --------------------------------------------------

SAFE_DATABASE=$(printf '%s' "$DATABASE" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
FILE_NAME="${SAFE_DATABASE}-${RUN_ID}.sql.gpg"
DUMP_FILE="${RUN_DIR}/${FILE_NAME}"
SHA_FILE="${DUMP_FILE}.sha256"
S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/${FILE_NAME}"
S3_SHA_URI="${S3_URI}.sha256"

# --------------------------------------------------
# Stream SQL into GPG without writing a plaintext dump; checksum ciphertext
# --------------------------------------------------

STAGE="DATABASE_DUMP"
log "Creating GPG-encrypted PostgreSQL SQL dump"
# Restore into an existing empty database. Manage ownership/grants separately.
pg_dump --no-password --format=plain --no-owner --no-acl |
    gpg --no-options --homedir "$GPG_HOME" --batch --no-tty \
        --trust-model always --recipient "$GPG_RECIPIENT" \
        --output "$DUMP_FILE" --encrypt
# pipefail stops the job if either pg_dump or GPG fails; no upload follows.

STAGE="CHECKSUM"
if [ ! -s "$DUMP_FILE" ]; then
    log "ERROR|Dump file is empty"
    exit 10
fi
SHA256=$(sha256sum "$DUMP_FILE" | awk '{print $1}')
printf '%s  %s\n' "$SHA256" "$FILE_NAME" > "$SHA_FILE"
SIZE=$(wc -c < "$DUMP_FILE" | tr -d '[:space:]')
log "DUMP_CREATED|SHA256=${SHA256}|SIZE=${SIZE}"

# --------------------------------------------------
# Upload encrypted SQL dump, then SHA256 file
# --------------------------------------------------

STAGE="UPLOAD_DUMP"
log "Uploading encrypted SQL dump to ${S3_URI}"
aws s3 cp "$DUMP_FILE" "$S3_URI" \
    --region "$REGION" \
    --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" \
    --checksum-algorithm SHA256 --only-show-errors

STAGE="UPLOAD_CHECKSUM"
log "Uploading SHA256 file"
aws s3 cp "$SHA_FILE" "$S3_SHA_URI" \
    --region "$REGION" \
    --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" \
    --checksum-algorithm SHA256 --content-type "text/plain" --only-show-errors

# --------------------------------------------------
# Verify both objects exist and record completion
# --------------------------------------------------

STAGE="VERIFY_UPLOADS"
aws s3api head-object --bucket "$S3_BUCKET" \
    --key "${S3_PREFIX}/${FILE_NAME}" --region "$REGION" > /dev/null
aws s3api head-object --bucket "$S3_BUCKET" \
    --key "${S3_PREFIX}/${FILE_NAME}.sha256" --region "$REGION" > /dev/null

STAGE="COMPLETED"
log "BACKUP_COMPLETED|S3_URI=${S3_URI}|SHA256=${SHA256}|SIZE=${SIZE}"
# The EXIT handler uploads the log on success or failure.
