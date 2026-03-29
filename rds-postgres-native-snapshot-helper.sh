#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash ./rds-postgres-native-snapshot-helper.sh

Required env vars:
  SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD
  SLOT_NAME DUMP_DIR

What it does:
  1. starts a repeatable-read transaction on source
  2. creates a logical replication slot
  3. exports a snapshot
  4. runs pg_dump --snapshot=...
  5. commits the transaction after the dump finishes

Outputs:
  $DUMP_DIR/baseline.dump
  $DUMP_DIR/snapshot-helper.log

Notes:
  - Run create-publication before this script.
  - If the slot already exists, this script will fail.
  - This script does not perform cutover.
EOF
}

require_env() {
  local missing=0
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "Missing required env var: $name" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

require_tools() {
  local missing=0
  for bin in psql pg_dump mktemp awk tail; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "Missing required tool: $bin" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

cleanup() {
  local exit_code=$?
  if [[ -n "${FIFO_PATH:-}" && -p "${FIFO_PATH:-}" ]]; then
    rm -f "$FIFO_PATH"
  fi
  if [[ -n "${PSQL_PID:-}" ]]; then
    wait "$PSQL_PID" 2>/dev/null || true
  fi
  exit "$exit_code"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD SLOT_NAME DUMP_DIR

  mkdir -p "$DUMP_DIR"

  local logfile="$DUMP_DIR/snapshot-helper.log"
  local dumpfile="$DUMP_DIR/baseline.dump"
  FIFO_PATH="$(mktemp -u "$DUMP_DIR/snapshot-helper.fifo.XXXXXX")"
  mkfifo "$FIFO_PATH"

  trap cleanup EXIT INT TERM

  : > "$logfile"

  echo "Opening source session and preparing consistent snapshot..."
  PGPASSWORD="$SRC_PASSWORD" \
  PGSSLMODE="${SRC_SSLMODE:-prefer}" \
  PGSSLROOTCERT="${SRC_SSLROOTCERT:-}" \
    psql -X -A -t -q -v ON_ERROR_STOP=1 \
      -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
      < "$FIFO_PATH" > "$logfile" 2>&1 &
  PSQL_PID=$!

  exec 3> "$FIFO_PATH"

  printf '%s\n' "BEGIN ISOLATION LEVEL REPEATABLE READ;" >&3
  printf '%s\n' "SELECT slot_name || '|' || lsn FROM pg_create_logical_replication_slot('$SLOT_NAME', 'pgoutput');" >&3
  printf '%s\n' "SELECT pg_export_snapshot();" >&3

  local waited=0
  local snapshot_name=""
  local slot_line=""
  while [[ "$waited" -lt 30 ]]; do
    if [[ -s "$logfile" ]]; then
      snapshot_name="$(awk '/^[0-9A-F-]+-[0-9A-F-]+-[0-9]+$/ { val=$0 } END { print val }' "$logfile")"
      slot_line="$(awk -F'|' 'NF==2 { val=$0 } END { print val }' "$logfile")"
      if [[ -n "$snapshot_name" && -n "$slot_line" ]]; then
        break
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [[ -z "$snapshot_name" ]]; then
    echo "Failed to capture exported snapshot name. Check $logfile" >&2
    exit 1
  fi

  echo "Slot and snapshot created:"
  echo "  ${slot_line:-<slot info unavailable>}"
  echo "  snapshot=$snapshot_name"
  echo "Starting baseline dump to $dumpfile"

  PGPASSWORD="$SRC_PASSWORD" \
  PGSSLMODE="${SRC_SSLMODE:-prefer}" \
  PGSSLROOTCERT="${SRC_SSLROOTCERT:-}" \
    pg_dump \
      -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
      --data-only \
      --format=custom \
      --no-owner \
      --no-privileges \
      --snapshot="$snapshot_name" \
      -f "$dumpfile"

  echo "Baseline dump finished. Releasing source transaction..."
  printf '%s\n' "COMMIT;" >&3
  exec 3>&-

  wait "$PSQL_PID"
  unset PSQL_PID

  echo "Done."
  echo "Baseline dump: $dumpfile"
  echo "Log file: $logfile"
}

main "$@"
