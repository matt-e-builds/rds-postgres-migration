# RDS PostgreSQL Native Migration Runbook

This runbook covers a near-zero-downtime migration using:

- `pg_dump --snapshot` for the baseline copy
- native PostgreSQL logical replication for catch-up
- a short write freeze for final cutover

It does not use AWS DMS.

## Start here

Before running any script, confirm the following:

1. The two script files and this runbook are in the same local folder.
2. The workstation can connect to both the source and target RDS endpoints on port `5432`.
3. A database username and password are available for both source and target.
4. The source RDS parameter group has `rds.logical_replication=1`.
5. The source and target PostgreSQL versions are compatible for native logical replication.
6. The implementation team can identify business-critical tables for the final verification step.

## Enable logical replication on the source RDS instance

Complete this on the source RDS for PostgreSQL instance before running the migration scripts:

1. Open the AWS RDS console.
2. Go to `Parameter groups`.
3. Create a custom DB parameter group for the correct PostgreSQL engine family if one does not already exist.
4. Edit the custom parameter group and set `rds.logical_replication` to `1`.
5. Associate that custom parameter group with the source RDS instance.
6. Reboot the source RDS instance so the static parameter change takes effect.
7. After the reboot, connect to the source database and verify:

```sql
SHOW rds.logical_replication;
SHOW wal_level;
SHOW max_replication_slots;
SHOW max_wal_senders;
```

Expected result:

- `rds.logical_replication` returns `on`
- `wal_level` is suitable for logical replication
- replication slot and WAL sender settings are nonzero

## Workstation prerequisites

The workstation used for the migration requires PostgreSQL client tools:

- `psql`
- `pg_dump`
- `pg_restore`

Example installation on macOS with Homebrew:

```bash
brew install postgresql@15
export PATH="/opt/homebrew/opt/postgresql@15/bin:/opt/homebrew/opt/libpq/bin:$PATH"
```

Verification:

```bash
psql --version
pg_dump --version
pg_restore --version
```

Expected result:

- each command returns a PostgreSQL version
- the major version should match the RDS PostgreSQL major version

## Quick path

This sequence is intended to be followed from a local workstation from start to finish.

1. Open a terminal in the folder containing the scripts.
2. Install PostgreSQL client tools if they are not already installed.
3. Copy `migration.env.example` to `migration.env`.
4. Open `migration.env` and replace every placeholder value with the real source and target connection details.
5. Load the environment variables into the current shell.
6. Run the precheck script and confirm source and target connectivity.
7. Run the primary-key check and review the output.
8. Dump the schema from source and restore it to target.
9. Create the publication on the source database.
10. Run the snapshot helper to create the logical replication slot and baseline dump.
11. Restore the baseline dump to target.
12. Create the subscription on target.
13. Monitor replication until caught up.
14. Perform cutover during a controlled change window.
15. Run the verification script as the final validation step.

Commands:

```bash
cd /path/to/this/folder

brew install postgresql@15
export PATH="/opt/homebrew/opt/postgresql@15/bin:/opt/homebrew/opt/libpq/bin:$PATH"
cp ./migration.env.example ./migration.env
# Update migration.env with real values before continuing
source ./migration.env

# Run the main migration script with the required subcommands
bash ./rds-postgres-native-migration.sh precheck
bash ./rds-postgres-native-migration.sh verify-replication-settings
bash ./rds-postgres-native-migration.sh check-pks
bash ./rds-postgres-native-migration.sh dump-schema
bash ./rds-postgres-native-migration.sh restore-schema
bash ./rds-postgres-native-migration.sh create-publication

# Run the snapshot helper script
bash ./rds-postgres-native-snapshot-helper.sh

# Return to the main migration script
bash ./rds-postgres-native-migration.sh restore-baseline
bash ./rds-postgres-native-migration.sh create-subscription
bash ./rds-postgres-native-migration.sh monitor
```

Cutover actions:

1. Place the application in read-only mode or stop writes to the source database.
2. Run `bash ./rds-postgres-native-migration.sh monitor` until replication lag is fully drained.
3. Redirect application connections to the target database.
4. Re-enable writes on the target database.
5. Run `bash ./rds-postgres-native-migration.sh session-check` to confirm client sessions have moved to the target.

Final verification:

1. Update `VALIDATION_TABLES` in `migration.env` with the business-critical tables that must be verified.
2. Run `source ./migration.env`.
3. Run `bash ./rds-postgres-verification.sh all`.
4. Review the row-count and checksum results.

## Automation scope

The migration workflow can be largely automated with shell scripts.

Automatable steps include:

- prechecks
- client version verification
- source logical replication settings verification
- schema export and restore
- publication creation
- baseline export with `pg_dump --snapshot`
- baseline restore with `pg_restore`
- subscription creation with `copy_data = false`
- replication monitoring
- source/target session comparison
- validation queries
- row-count comparison
- ordered checksum comparison for selected tables

The production cutover remains a controlled operational activity.

The following steps require explicit operator approval:

- application write freeze or write drain
- final replication verification
- validation review
- go/no-go cutover decision
- rollback decision if validation does not pass

The consistency-sensitive part of the workflow is the baseline export. The snapshot-holding session must remain open while `pg_dump --snapshot` starts and uses the exported snapshot.

## Preconditions

- Source is Amazon RDS for PostgreSQL.
- Target is a new Amazon RDS for PostgreSQL instance.
- Source and target major versions are compatible for native logical replication.
- Tables to be replicated have primary keys.
- Schema on target matches source before subscription starts.
- You can temporarily stop or drain writes during cutover.
- `rds.logical_replication=1` is enabled on source parameter group.
- Migration user has enough rights on source and target.

AWS references:

- RDS logical replication: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.FeatureSupport.LogicalReplication.html>
- `pglogical` on RDS: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.pglogical.html>

Community reference for the exact `pg_dump --snapshot` alignment pattern:

- <https://dba.stackexchange.com/questions/349367/postgres-logical-replication-to-restored-snapshot>

## Variables

Set these before running commands if `migration.env` is not used:

```bash
export SRC_HOST="source.xxxxx.us-east-1.rds.amazonaws.com"
export SRC_PORT="5432"
export SRC_DB="appdb"
export SRC_USER="migration_user"
export SRC_PASSWORD="source_password"
export SRC_SSLMODE="require"
export SRC_SSLROOTCERT=""

export TGT_HOST="target.xxxxx.us-east-1.rds.amazonaws.com"
export TGT_PORT="5432"
export TGT_DB="appdb"
export TGT_USER="migration_user"
export TGT_PASSWORD="target_password"
export TGT_SSLMODE="require"
export TGT_SSLROOTCERT=""

export PUB_NAME="migration_pub"
export SUB_NAME="migration_sub"
export SLOT_NAME="migration_slot"

export DUMP_DIR="$PWD/migration-artifacts"
mkdir -p "$DUMP_DIR"
```

Credentials can be provided through `PGPASSWORD` or a `.pgpass` file.

## Running from a local laptop

This runbook is intended to be executed from a local workstation or another host with connectivity to both RDS endpoints.

You need:

- PostgreSQL client tools installed: `psql`, `pg_dump`, `pg_restore`
- network connectivity from the workstation to both RDS endpoints
- database credentials for source and target
- either `PGPASSWORD` set per command/session or a `.pgpass` file

For this tested migration path against PostgreSQL 15 RDS instances, use PostgreSQL 15 client tools. If the tools were installed through Homebrew, add the following to the shell session before running the scripts:

```bash
export PATH="/opt/homebrew/opt/postgresql@15/bin:/opt/homebrew/opt/libpq/bin:$PATH"
```

You do not need AWS CLI for the database dump and restore commands. `pg_dump`, `pg_restore`, and `psql` connect directly to the RDS hostname and port.

An example `.pgpass` entry:

```text
source.xxxxx.us-east-1.rds.amazonaws.com:5432:appdb:migration_user:source_password
target.xxxxx.us-east-1.rds.amazonaws.com:5432:appdb:migration_user:target_password
```

Then secure it:

```bash
chmod 600 ~/.pgpass
```

The following files are included in this directory:

```bash
cat ./migration.env.example
bash ./rds-postgres-native-migration.sh help
bash ./rds-postgres-native-snapshot-helper.sh --help
bash ./rds-postgres-verification.sh help
```

`migration.env.example` is the checked-in template. Copy it to `migration.env`, replace every placeholder value, and keep `migration.env` local. `VALIDATION_TABLES` can remain empty until the final verification step.

If the target requires certificate validation, download the RDS trust bundle and set the target SSL variables accordingly:

```bash
curl -o global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
export TGT_SSLMODE="verify-full"
export TGT_SSLROOTCERT="$PWD/global-bundle.pem"
```

Template contents:

```bash
export SRC_HOST="source.xxxxx.us-east-1.rds.amazonaws.com"
export SRC_PORT="5432"
export SRC_DB="appdb"
export SRC_USER="migration_user"
export SRC_PASSWORD="source_password"
export SRC_SSLMODE="require"
export SRC_SSLROOTCERT=""

export TGT_HOST="target.xxxxx.us-east-1.rds.amazonaws.com"
export TGT_PORT="5432"
export TGT_DB="appdb"
export TGT_USER="migration_user"
export TGT_PASSWORD="target_password"
export TGT_SSLMODE="require"
export TGT_SSLROOTCERT=""

export PUB_NAME="migration_pub"
export SUB_NAME="migration_sub"
export SLOT_NAME="migration_slot"

export DUMP_DIR="$PWD/migration-artifacts"
export VALIDATION_TABLES=""
```

## 1. Prepare source

Confirm logical replication settings:

```sql
SHOW rds.logical_replication;
SHOW wal_level;
SHOW max_replication_slots;
SHOW max_wal_senders;
```

The same verification can be run through the script:

```bash
bash ./rds-postgres-native-migration.sh verify-replication-settings
```

Confirm primary keys exist on replicated tables:

```sql
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
```

Create the publication:

```sql
CREATE PUBLICATION migration_pub FOR ALL TABLES;
```

For selected tables only:

```sql
CREATE PUBLICATION migration_pub
FOR TABLE public.table1, public.table2;
```

## 2. Prepare target schema

Dump schema from source:

```bash
pg_dump \
  -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
  --schema-only --no-owner --no-privileges \
  -f "$DUMP_DIR/schema.sql"
```

Restore schema to target:

```bash
psql \
  -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" \
  -f "$DUMP_DIR/schema.sql"
```

## 3. Create replication slot and export a consistent snapshot

Use the snapshot helper script for this step:

```bash
bash ./rds-postgres-native-snapshot-helper.sh
```

The helper performs the following actions:

- opens a source session
- starts a repeatable-read transaction
- creates the logical replication slot
- exports a snapshot
- runs `pg_dump --snapshot=...` while that transaction stays open
- commits only after the dump finishes

Output files:

- `$DUMP_DIR/baseline.dump`
- `$DUMP_DIR/snapshot-helper.log`

The helper script automates the following sequence:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT * FROM pg_create_logical_replication_slot('migration_slot', 'pgoutput');
SELECT pg_export_snapshot();
```

Then:

```bash
pg_dump \
  -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
  --data-only \
  --format=custom \
  --no-owner \
  --no-privileges \
  --snapshot="<SNAPSHOT_NAME>" \
  -f "$DUMP_DIR/baseline.dump"
```

The transaction must stay open until `pg_dump` has started using the exported snapshot.

## 4. Baseline data dump from the exported snapshot

If the helper script is not used, run the following command while the snapshot-holding session remains open:

```bash
pg_dump \
  -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
  --data-only \
  --format=custom \
  --no-owner \
  --no-privileges \
  --snapshot="<SNAPSHOT_NAME>" \
  -f "$DUMP_DIR/baseline.dump"
```

After `pg_dump` starts and attaches to the exported snapshot, the coordinator transaction can be ended.

## 5. Restore baseline data to target

```bash
pg_restore \
  -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" \
  --data-only \
  --no-owner \
  --no-privileges \
  "$DUMP_DIR/baseline.dump"
```

## 6. Create the subscription on target

Do not allow PostgreSQL to perform an additional initial table copy.

```sql
CREATE SUBSCRIPTION migration_sub
CONNECTION 'host=''<SRC_HOST>'' port=''<SRC_PORT>'' dbname=''<SRC_DB>'' user=''<SRC_USER>'' password=''<PASSWORD>'''
PUBLICATION migration_pub
WITH (
  copy_data = false,
  create_slot = false,
  slot_name = 'migration_slot',
  enabled = true
);
```

Example after variable substitution:

```sql
CREATE SUBSCRIPTION migration_sub
CONNECTION 'host=source.xxxxx.us-east-1.rds.amazonaws.com port=5432 dbname=appdb user=migration_user password=secret'
PUBLICATION migration_pub
WITH (
  copy_data = false,
  create_slot = false,
  slot_name = 'migration_slot',
  enabled = true
);
```

## 7. Monitor replication

On target:

```sql
SELECT subname, pid, relid, received_lsn, latest_end_lsn, latest_end_time
FROM pg_stat_subscription;
```

On source:

```sql
SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name = 'migration_slot';
```

If the slot is not consumed, WAL retention grows on source.

Connection retry behavior:

- `precheck`, `monitor`, and `session-check` retry connectivity automatically
- default retries: `3`
- default sleep between retries: `2` seconds

Optional overrides:

```bash
export CONNECT_RETRIES="5"
export CONNECT_RETRY_SLEEP="3"
```

## 8. Validation before cutover

Row counts for critical tables:

```sql
SELECT 'public.table1' AS table_name, count(*) FROM public.table1
UNION ALL
SELECT 'public.table2' AS table_name, count(*) FROM public.table2;
```

Spot-check max IDs or timestamps:

```sql
SELECT max(id), max(updated_at) FROM public.table1;
```

Sequence alignment on target may need adjustment after baseline restore:

```sql
SELECT setval(
  pg_get_serial_sequence('public.table1', 'id'),
  COALESCE((SELECT max(id) FROM public.table1), 1),
  true
);
```

The verification script is intended to run separately at the end of the migration. It performs row-count comparison and checksum comparison for the tables listed in `VALIDATION_TABLES`:

```bash
bash ./rds-postgres-verification.sh counts
bash ./rds-postgres-verification.sh checksum
bash ./rds-postgres-verification.sh all
```

The checksum routine:

- requires each validation table to have a primary key
- orders rows by primary key
- converts each row to canonical JSON text
- calculates a SHA-256 digest of the ordered stream on source and target
- compares the resulting digest values

This provides stronger verification than row counts alone, but it can be expensive on large tables.

## 9. Cutover

1. Put the application in read-only mode or stop writes.
2. Wait for subscription lag to drain.
3. Point the application to target.
4. Resume writes on target.
5. Run `bash ./rds-postgres-native-migration.sh session-check`.
6. Confirm application sessions have drained from source and appear on target.

The write freeze is generally short when replication lag is already near zero before cutover.

## 10. Rollback

If cutover validation fails before reopening writes on target:

1. keep source as system of record
2. drop or disable the target subscription
3. fix the issue
4. repeat validation and cutover later

If writes already resumed on target, rollback is no longer trivial and needs a separate reverse-sync plan.

## 11. Cleanup

After stabilization:

```sql
DROP SUBSCRIPTION migration_sub;
```

On source:

```sql
SELECT pg_drop_replication_slot('migration_slot');
```

If no longer required, drop the publication:

```sql
DROP PUBLICATION migration_pub;
```

## Scripts in this folder

`rds-postgres-native-migration.sh`

- phase-based helper for precheck, replication settings verification, schema, publication, restore, subscription, monitoring, session comparison, and validation

`rds-postgres-native-snapshot-helper.sh`

- helper for the consistency-sensitive part: create slot, export snapshot, run baseline dump, then release the transaction

`rds-postgres-verification.sh`

- helper for row-count and checksum verification on selected tables before cutover

## Scriptable skeleton

This shows the intended operator flow:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${SRC_HOST:?}"
: "${SRC_PORT:?}"
: "${SRC_DB:?}"
: "${SRC_USER:?}"
: "${TGT_HOST:?}"
: "${TGT_PORT:?}"
: "${TGT_DB:?}"
: "${TGT_USER:?}"
: "${PUB_NAME:?}"
: "${SUB_NAME:?}"
: "${SLOT_NAME:?}"

mkdir -p "$DUMP_DIR"

echo "Dumping schema"
pg_dump \
  -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
  --schema-only --no-owner --no-privileges \
  -f "$DUMP_DIR/schema.sql"

echo "Restoring schema"
psql \
  -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" \
  -f "$DUMP_DIR/schema.sql"

echo "Ensure publication exists"
psql \
  -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
  -c "CREATE PUBLICATION $PUB_NAME FOR ALL TABLES;"

echo "Running snapshot helper"
bash ./rds-postgres-native-snapshot-helper.sh

echo "Restoring baseline"
pg_restore \
  -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_DB" \
  --data-only --no-owner --no-privileges \
  "$DUMP_DIR/baseline.dump"

echo "Create subscription with create_slot=false and copy_data=false"
echo "Freeze writes, validate lag=0, and perform cutover"
```

## Implementation recommendation

Most of the migration workflow can be automated with shell scripts, including schema export and restore, publication creation, baseline export, baseline restore, subscription creation, replication monitoring, and validation queries.

For production execution, the cutover remains a controlled operational step. The application write freeze, final replication verification, validation review, and endpoint switchover require explicit operator approval so the implementation team can confirm replication state and make a deliberate go/no-go decision.

## Test findings

The migration test surfaced the following operational requirements:

- PostgreSQL 15 client tools should be used for PostgreSQL 15 RDS instances
- PostgreSQL 18 client tools generated schema SQL that did not restore cleanly to PostgreSQL 15
- replication caught up correctly through native logical replication after baseline load
- table count and checksum verification succeeded for the selected tables
- session checks should be used after cutover to confirm application connections have moved from source to target
