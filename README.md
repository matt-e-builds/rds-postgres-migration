# RDS PostgreSQL Native Migration

This repository contains a tested near-zero-downtime migration workflow for Amazon RDS for PostgreSQL using:

- `pg_dump --snapshot` for the baseline copy
- native PostgreSQL logical replication for change catch-up
- a short write freeze for cutover

It does not use AWS DMS.

## Files

- `migration.env.example`: template for source and target connection settings
- `rds-postgres-native-migration.sh`: main migration script
- `rds-postgres-native-snapshot-helper.sh`: baseline snapshot and dump helper
- `rds-postgres-verification.sh`: row-count and checksum verification script
- `rds-postgres-native-migration-runbook.md`: detailed reference notes

## Prerequisites

1. Source and target are Amazon RDS for PostgreSQL.
2. Source and target PostgreSQL major versions are compatible.
3. Source RDS has `rds.logical_replication=1` enabled through a custom parameter group and the source instance has been rebooted.
4. The workstation can connect to both RDS endpoints on port `5432`.
5. PostgreSQL 15 client tools are installed for this tested path.

Install the tested client version on macOS with Homebrew:

```bash
brew install postgresql@15
export PATH="/opt/homebrew/opt/postgresql@15/bin:/opt/homebrew/opt/libpq/bin:$PATH"
```

Verify:

```bash
psql --version
pg_dump --version
pg_restore --version
```

Expected result:

- each command returns PostgreSQL 15

## Source setup

Enable logical replication on the source RDS instance:

1. Open the AWS RDS console.
2. Go to `Parameter groups`.
3. Create or use a custom DB parameter group for the correct PostgreSQL engine family.
4. Set `rds.logical_replication` to `1`.
5. Associate that parameter group with the source RDS instance.
6. Reboot the source RDS instance.

Verify from PostgreSQL:

```bash
bash ./rds-postgres-native-migration.sh verify-replication-settings
```

Expected result:

- `rds.logical_replication = on`
- `wal_level = logical`
- replication slot and WAL sender settings are nonzero

## Quick Path

1. Open a terminal in this folder.
2. Copy `migration.env.example` to `migration.env`.
3. Replace placeholder values in `migration.env`.
4. Load the environment variables.
5. Run the migration commands in order.

Commands:

```bash
cd /path/to/this/folder

export PATH="/opt/homebrew/opt/postgresql@15/bin:/opt/homebrew/opt/libpq/bin:$PATH"
cp ./migration.env.example ./migration.env
# Update migration.env with real values before continuing
source ./migration.env

bash ./rds-postgres-native-migration.sh precheck
bash ./rds-postgres-native-migration.sh verify-replication-settings
bash ./rds-postgres-native-migration.sh check-pks
bash ./rds-postgres-native-migration.sh dump-schema
bash ./rds-postgres-native-migration.sh restore-schema
bash ./rds-postgres-native-migration.sh create-publication
bash ./rds-postgres-native-snapshot-helper.sh
bash ./rds-postgres-native-migration.sh restore-baseline
bash ./rds-postgres-native-migration.sh create-subscription
bash ./rds-postgres-native-migration.sh monitor
```

## Cutover

1. Place the application in read-only mode or stop writes to the source database.
2. Run `bash ./rds-postgres-native-migration.sh monitor` until replication is caught up.
3. Change the application database host from source to target.
4. Re-enable writes on the target.
5. Run `bash ./rds-postgres-native-migration.sh session-check`.
6. Confirm source client sessions have drained and application sessions are present on target.

## Verification

After cutover, update `VALIDATION_TABLES` in `migration.env` with schema-qualified business tables and run:

```bash
source ./migration.env
bash ./rds-postgres-verification.sh all
```

This performs:

- row-count comparison
- ordered checksum comparison

## Notes

- `migration.env` should remain local and is ignored by git.
- `migration.env.example` is the tracked template.
- If connectivity is intermittent, `precheck`, `monitor`, and `session-check` support retry controls through:

```bash
export CONNECT_RETRIES="5"
export CONNECT_RETRY_SLEEP="3"
```

## Detailed Reference

For extended notes and supporting detail, see `rds-postgres-native-migration-runbook.md`.
