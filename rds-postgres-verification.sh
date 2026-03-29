#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash ./rds-postgres-verification.sh <command>

Commands:
  help       Show this help
  counts     Compare row counts for VALIDATION_TABLES
  checksum   Compare ordered SHA-256 checksums for VALIDATION_TABLES
  all        Run counts and checksum

Required env vars:
  SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD
  TGT_HOST TGT_PORT TGT_DB TGT_USER TGT_PASSWORD
  VALIDATION_TABLES

Notes:
  - VALIDATION_TABLES must be a space-separated list such as:
      export VALIDATION_TABLES="public.table1 public.table2"
  - checksum requires each table to have a primary key.
  - checksum can be expensive on large tables because it reads the full table on both source and target.
EOF
}

require_tools() {
  local missing=0
  for bin in psql awk sed; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "Missing required tool: $bin" >&2
      missing=1
    fi
  done
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "Missing required tool: shasum or sha256sum" >&2
    missing=1
  fi
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
  PGSSLMODE="${SRC_SSLMODE:-prefer}" \
  PGSSLROOTCERT="${SRC_SSLROOTCERT:-}" \
    psql -X -A -t -q -v ON_ERROR_STOP=1 \
      -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" "$@"
}

tgt_psql() {
  PGPASSWORD="${TGT_PASSWORD:-${PGPASSWORD:-}}" \
  PGSSLMODE="${TGT_SSLMODE:-prefer}" \
  PGSSLROOTCERT="${TGT_SSLROOTCERT:-}" \
    psql -X -A -t -q -v ON_ERROR_STOP=1 \
      -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" "$@"
}

hash_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

split_table() {
  local table="$1"
  if [[ "$table" != *.* ]]; then
    echo "Table must be schema-qualified: $table" >&2
    exit 1
  fi
  local schema="${table%%.*}"
  local rel="${table#*.}"
  printf '%s\n%s\n' "$schema" "$rel"
}

sql_ident() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
}

pk_order_expr() {
  local schema="$1"
  local rel="$2"
  src_psql <<SQL
SELECT string_agg(format('%I', a.attname), ', ' ORDER BY u.ordinality)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
JOIN unnest(i.indkey) WITH ORDINALITY AS u(attnum, ordinality) ON true
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
WHERE n.nspname = '$schema'
  AND c.relname = '$rel';
SQL
}

compare_counts() {
  for table in $VALIDATION_TABLES; do
    local src_count tgt_count
    src_count="$(src_psql -c "SELECT count(*) FROM $table;")"
    tgt_count="$(tgt_psql -c "SELECT count(*) FROM $table;")"
    if [[ "$src_count" == "$tgt_count" ]]; then
      echo "COUNT OK    $table    $src_count"
    else
      echo "COUNT FAIL  $table    source=$src_count target=$tgt_count"
      return 1
    fi
  done
}

table_checksum() {
  local host="$1"
  local port="$2"
  local db="$3"
  local user="$4"
  local password="$5"
  local schema="$6"
  local rel="$7"
  local order_expr="$8"
  local schema_q rel_q
  schema_q="$(sql_ident "$schema")"
  rel_q="$(sql_ident "$rel")"

  PGPASSWORD="$password" \
  PGSSLMODE="${9:-prefer}" \
  PGSSLROOTCERT="${10:-}" \
    psql -X -A -t -q -v ON_ERROR_STOP=1 \
      -h "$host" -p "$port" -U "$user" -d "$db" \
      -c "COPY (SELECT row_to_json(t)::text FROM (SELECT * FROM ${schema_q}.${rel_q} ORDER BY ${order_expr}) AS t) TO STDOUT;" \
    | hash_stream
}

compare_checksums() {
  for table in $VALIDATION_TABLES; do
    local schema rel order_expr src_hash tgt_hash
    schema="$(split_table "$table" | sed -n '1p')"
    rel="$(split_table "$table" | sed -n '2p')"
    order_expr="$(pk_order_expr "$schema" "$rel")"
    if [[ -z "$order_expr" ]]; then
      echo "CHECKSUM FAIL  $table    no primary key found"
      return 1
    fi
    src_hash="$(table_checksum "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "$SRC_USER" "$SRC_PASSWORD" "$schema" "$rel" "$order_expr" "${SRC_SSLMODE:-prefer}" "${SRC_SSLROOTCERT:-}")"
    tgt_hash="$(table_checksum "$TGT_HOST" "$TGT_PORT" "$TGT_DB" "$TGT_USER" "$TGT_PASSWORD" "$schema" "$rel" "$order_expr" "${TGT_SSLMODE:-prefer}" "${TGT_SSLROOTCERT:-}")"
    if [[ "$src_hash" == "$tgt_hash" ]]; then
      echo "CHECKSUM OK    $table    $src_hash"
    else
      echo "CHECKSUM FAIL  $table    source=$src_hash target=$tgt_hash"
      return 1
    fi
  done
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    counts)
      require_tools
      require_env SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD TGT_HOST TGT_PORT TGT_DB TGT_USER TGT_PASSWORD VALIDATION_TABLES
      compare_counts
      ;;
    checksum)
      require_tools
      require_env SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD TGT_HOST TGT_PORT TGT_DB TGT_USER TGT_PASSWORD VALIDATION_TABLES
      compare_checksums
      ;;
    all)
      require_tools
      require_env SRC_HOST SRC_PORT SRC_DB SRC_USER SRC_PASSWORD TGT_HOST TGT_PORT TGT_DB TGT_USER TGT_PASSWORD VALIDATION_TABLES
      compare_counts
      compare_checksums
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
