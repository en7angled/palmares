#!/usr/bin/env bash
# The privilege separation is the CONTROL for co-locating our schemas in db-sync's database.
#
# ADR 0001 chose one database over two, because every view we publish reads db-sync's tables and a
# cross-database join is not a thing. The price is that our service's credentials live inside the
# database db-sync writes. This script asserts that they cannot touch it — it does not assume it.
#
# Runs against either target:
#
#   * the experiment, off-cluster:
#       PSQL='docker exec -i palmares-dbsync-exp-postgres-1 psql -U postgres -d cexplorer' \
#       DBSYNC_ROLE=postgres scripts/check_roles.sh
#
#   * the cluster (the default):
#       scripts/check_roles.sh
#
# Every check is a single `SELECT <expr>` that must come back `t`. A NULL (the role does not exist,
# so the subselect returns no row) is not `t`, so a missing role fails rather than passing quietly.
set -euo pipefail

: "${PSQL:=kubectl --context minirack-lan -n cardano-preprod exec -i deploy/deployment-palmares-postgres -- psql -U dbsync -d cexplorer}"
# Whoever owns db-sync's tables and therefore whose ALTER DEFAULT PRIVILEGES entry matters. The
# cluster's superuser is `dbsync`; the experiment's compose file brought the database up as
# `postgres`, and a default-privileges row is keyed by the CREATING role, so the check has to know.
: "${DBSYNC_ROLE:=dbsync}"

q() { $PSQL -At -c "$1"; }

fail=0
chk() {
  local got
  got="$(q "SELECT $2;" 2>&1 || true)"
  if [ "$got" = t ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    [ -n "$got" ] && [ "$got" != f ] && echo "       -> $got"
    fail=1
  fi
}

echo "# Role separation — $(date -u '+%Y-%m-%dT%H:%M:%SZ')  (db-sync owner role: $DBSYNC_ROLE)"

chk "palmares_owner exists, can log in, is not superuser" \
  "(SELECT rolcanlogin AND NOT rolsuper FROM pg_roles WHERE rolname='palmares_owner')"
chk "palmares_ro exists, can log in, is not superuser" \
  "(SELECT rolcanlogin AND NOT rolsuper FROM pg_roles WHERE rolname='palmares_ro')"

# The two roles must be able to read the substrate...
chk "palmares_ro may read db-sync's tables" \
  "has_table_privilege('palmares_ro','public.voting_procedure','SELECT')"
chk "palmares_owner may read db-sync's tables" \
  "has_table_privilege('palmares_owner','public.voting_procedure','SELECT')"

# ...and nothing more. These four are the whole point of the file.
chk "palmares_ro may NOT write db-sync's tables" \
  "NOT has_table_privilege('palmares_ro','public.voting_procedure','INSERT')"
chk "palmares_owner may NOT write db-sync's tables" \
  "NOT has_table_privilege('palmares_owner','public.voting_procedure','INSERT')"
chk "palmares_ro may NOT create in public" \
  "NOT has_schema_privilege('palmares_ro','public','CREATE')"
chk "palmares_owner may NOT create in public" \
  "NOT has_schema_privilege('palmares_owner','public','CREATE')"

chk "palmares_owner may create the palmares schema" \
  "has_database_privilege('palmares_owner','cexplorer','CREATE')"
chk "palmares_ro may NOT create a schema" \
  "NOT has_database_privilege('palmares_ro','cexplorer','CREATE')"
chk "palmares_attest is owned by palmares_owner" \
  "(SELECT nspowner = 'palmares_owner'::regrole FROM pg_namespace WHERE nspname='palmares_attest')"

chk "search_path resolves unqualified names for palmares_ro" \
  "(SELECT 'search_path=palmares, palmares_attest, public' = ANY(rolconfig) FROM pg_roles WHERE rolname='palmares_ro')"
chk "search_path resolves unqualified names for palmares_owner" \
  "(SELECT 'search_path=palmares, palmares_attest, public' = ANY(rolconfig) FROM pg_roles WHERE rolname='palmares_owner')"

# Future-proofing: a db-sync migration that adds a table must not need a re-GRANT. Without this,
# every db-sync upgrade would silently leave new tables unreadable, and a view over one of them
# would fail at read time with a permission error that reads like a bug in the view.
chk "default privileges cover tables db-sync creates later in public" \
  "(SELECT count(*) > 0 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace
      WHERE n.nspname='public' AND d.defaclobjtype='r' AND d.defaclrole = '$DBSYNC_ROLE'::regrole
        AND array_to_string(d.defaclacl,',') LIKE '%palmares_ro=r%')"

# The same hazard one schema over, and this one is on the only path there is: `chain_cursor` is
# created by attest-sync, which every committed configuration connects as `postgres` rather than
# `palmares_owner`. The explicit GRANT in sql/050_roles.sql resolves when it runs, so it covers
# nothing if `apply-roles` precedes attest-sync's first boot, and the absence is unreadable from the
# outside: information_schema shows only what the role may see, so /status serves
# `attest_lag_seconds: null` and the smoke flow reads that as attest-sync never having run.
chk "default privileges cover the table attest-sync creates in palmares_attest" \
  "(SELECT count(*) > 0 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace
      WHERE n.nspname='palmares_attest' AND d.defaclobjtype='r'
        AND d.defaclrole = '$DBSYNC_ROLE'::regrole
        AND array_to_string(d.defaclacl,',') LIKE '%palmares_ro=r%')"

# The grant that `DROP SCHEMA palmares CASCADE` destroys on every query-api boot, re-made by
# sql/040_grants.sql as the LAST statement of the boot transaction. Checked here because its
# absence is invisible until a restart, and then it is every governance route returning 500.
# Skipped rather than failed when the schema is not there: this script is also run before the
# service's first boot, and `admin apply-roles` does not create `palmares`.
if [ "$(q "SELECT count(*) FROM pg_namespace WHERE nspname='palmares';")" = 1 ]; then
  chk "palmares_ro has USAGE on the palmares schema (re-granted by sql/040_grants.sql)" \
    "has_schema_privilege('palmares_ro','palmares','USAGE')"
  chk "palmares_ro has SELECT on every view and matview in palmares" \
    "(SELECT coalesce(bool_and(has_table_privilege('palmares_ro', c.oid, 'SELECT')), false)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname='palmares' AND c.relkind IN ('v','m'))"
else
  echo "skip palmares schema not applied yet — query-api has not booted against this database"
fi

if [ "$fail" = 0 ]; then echo "roles OK"; else echo "roles FAILED"; fi
exit $fail
