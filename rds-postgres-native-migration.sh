#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./rds-postgres-native-migration.sh <command>

Commands:
  help                 Show this help
  precheck             Verify required env vars and local tools
  check-pks            List user tables without primary keys on source
  dump-schema          Dump schema from source to $DUMP_DIR/schema.sql
  restore-schema       Restore $DUMP_DIR/schema.sql to target
  create-publication   Create publication on source
  dump-baseline        Run pg_dump --snapshot=$SNAPSHOT_NAME to baseline.dump
  restore-baseline     Restore baseline.dump to target
  create-subscription  Create target subscription with copy_data=false
  monitor              Show slot/subscription state
  validate             Run basic validation queries

Required env vars:
  SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD
  TGT_HOST TGT_PORT TGT_DB TGT_USER TGT_PASSWORD
  PUB_NAME SUB_NAME SLOT_NAME DUMP_DIR

Additional env vars:
  SNAPSHOT_NAME        Required for dump-baseline
  PUBLICATION_TABLES   Optional. Example: "public.t1, public.t2"
  VALIDATION_TABLES    Optional. Example: "public.t1 public.t2"

Notes:
  - This script is meant to be run from a laptop or host that can reach both RDS instances.
  - It does not automate the exported snapshot session or final app cutover.
  - Use .pgpass instead of *_PASSWORD env vars if you prefer.
EOF
}

require_tools() {
  local missing=0
  for bin in psql pg_dump pg_restore; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "Missing required tool: $bin" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
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

src_psql() {
  PGPASSWORD="${SRC_PASSWORD:-${PGPASSWORD:-}}" \
    psql -v ON_ERROR_STOP=1 \
      -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" "$@"
}

tgt_psql() {
  PGPASSWORD="${TGT_PASSWORD:-${PGPASSWORD:-}}" \
    psql -v ON_ERROR_STOP=1 \
      -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" "$@"
}

src_dump() {
  PGPASSWORD="${SRC_PASSWORD:-${PGPASSWORD:-}}" \
    pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" "$@"
}

tgt_restore() {
  PGPASSWORD="${TGT_PASSWORD:-${PGPASSWORD:-}}" \
    pg_restore -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" "$@"
}

sql_escape_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

ensure_dump_dir() {
  mkdir -p "$DUMP_DIR"
}

command_precheck() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER TGT_HOST TGT_PORT TGT_DB TGT_USER PUB_NAME SUB_NAME SLOT_NAME DUMP_DIR
  ensure_dump_dir
  echo "Tools present."
  echo "Artifacts dir: $DUMP_DIR"
  echo "Checking source connectivity..."
  src_psql -c "SELECT version();"
  echo "Checking target connectivity..."
  tgt_psql -c "SELECT version();"
}

command_check_pks() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER
  src_psql <<'SQL'
SELECT n.nspname AS schema_name,
       c.relname AS table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_constraint con
  ON con.conrelid = c.oid
 AND con.contype = 'p'
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND con.oid IS NULL
ORDER BY 1, 2;
SQL
}

command_dump_schema() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER DUMP_DIR
  ensure_dump_dir
  src_dump --schema-only --no-owner --no-privileges -f "$DUMP_DIR/schema.sql"
  echo "Wrote $DUMP_DIR/schema.sql"
}

command_restore_schema() {
  require_tools
  require_env TGT_HOST TGT_PORT TGT_DB TGT_USER DUMP_DIR
  [[ -f "$DUMP_DIR/schema.sql" ]] || { echo "Missing $DUMP_DIR/schema.sql" >&2; exit 1; }
  tgt_psql -f "$DUMP_DIR/schema.sql"
}

command_create_publication() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER PUB_NAME
  local sql
  if [[ -n "${PUBLICATION_TABLES:-}" ]]; then
    sql="CREATE PUBLICATION \"$PUB_NAME\" FOR TABLE $PUBLICATION_TABLES;"
  else
    sql="CREATE PUBLICATION \"$PUB_NAME\" FOR ALL TABLES;"
  fi
  src_psql -c "$sql"
}

command_dump_baseline() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER DUMP_DIR SNAPSHOT_NAME
  ensure_dump_dir
  src_dump \
    --data-only \
    --format=custom \
    --no-owner \
    --no-privileges \
    --snapshot="$SNAPSHOT_NAME" \
    -f "$DUMP_DIR/baseline.dump"
  echo "Wrote $DUMP_DIR/baseline.dump"
}

command_restore_baseline() {
  require_tools
  require_env TGT_HOST TGT_PORT TGT_DB TGT_USER DUMP_DIR
  [[ -f "$DUMP_DIR/baseline.dump" ]] || { echo "Missing $DUMP_DIR/baseline.dump" >&2; exit 1; }
  tgt_restore --data-only --no-owner --no-privileges "$DUMP_DIR/baseline.dump"
}

command_create_subscription() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD TGT_HOST TGT_PORT TGT_DB TGT_USER SUB_NAME PUB_NAME SLOT_NAME
  local conn
  conn="host=$(sql_escape_literal "$SRC_HOST") port=$(sql_escape_literal "$SRC_PORT") dbname=$(sql_escape_literal "$SRC_DB") user=$(sql_escape_literal "$SRC_USER") password=$(sql_escape_literal "$SRC_PASSWORD")"
  tgt_psql <<SQL
CREATE SUBSCRIPTION "$SUB_NAME"
CONNECTION '$conn'
PUBLICATION "$PUB_NAME"
WITH (
  copy_data = false,
  create_slot = false,
  slot_name = '$SLOT_NAME',
  enabled = true
);
SQL
}

command_monitor() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER SLOT_NAME TGT_HOST TGT_PORT TGT_DB TGT_USER
  echo "Source slot state:"
  src_psql -c "SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';"
  echo
  echo "Target subscription state:"
  tgt_psql -c "SELECT subname, pid, relid, received_lsn, latest_end_lsn, latest_end_time FROM pg_stat_subscription;"
}

command_validate() {
  require_tools
  require_env SRC_HOST SRC_PORT SRC_DB SRC_USER TGT_HOST TGT_PORT TGT_DB TGT_USER
  if [[ -z "${VALIDATION_TABLES:-}" ]]; then
    echo "Set VALIDATION_TABLES to a space-separated list, for example: public.table1 public.table2" >&2
    exit 1
  fi
  for table in $VALIDATION_TABLES; do
    echo "Counts for $table"
    src_psql -t -A -c "SELECT count(*) FROM $table;"
    tgt_psql -t -A -c "SELECT count(*) FROM $table;"
    echo
  done
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help) usage ;;
    precheck) command_precheck ;;
    check-pks) command_check_pks ;;
    dump-schema) command_dump_schema ;;
    restore-schema) command_restore_schema ;;
    create-publication) command_create_publication ;;
    dump-baseline) command_dump_baseline ;;
    restore-baseline) command_restore_baseline ;;
    create-subscription) command_create_subscription ;;
    monitor) command_monitor ;;
    validate) command_validate ;;
    *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
