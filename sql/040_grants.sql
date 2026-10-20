-- The grants for the read-only serving role, and the last thing the boot transaction does.
--
-- __Why this file has to exist.__ `000_schema.sql` opens with `DROP SCHEMA palmares CASCADE`, which
-- destroys every privilege on that schema along with the objects in it — and the `pg_default_acl`
-- row too, so `ALTER DEFAULT PRIVILEGES` cannot carry it. The grants therefore have to be re-made
-- on every boot, inside the same transaction that re-creates the schema.
--
-- Omit it and the two-role deployment serves 500s on every governance route the first time
-- query-api restarts: the views are there, and the role serving requests has no USAGE on their
-- schema. Nothing before this file grants anything, so that is not a hypothetical.
--
-- __And it has to be LAST.__ `ON ALL TABLES` resolves to the relations that exist when it runs, so
-- the same statement placed before `030_metrics.sql` would silently miss `palmares.drep_metrics`.
--
-- `ALL TABLES` does cover views AND materialized views — measured on PostgreSQL 17, where a matview
-- reads `has_table_privilege = true` after this one statement — so the matview needs no separate
-- grant and `ALL SEQUENCES` is not needed at all (this schema has none).

-- __Guarded on the role existing__, because the single-role deployment is still supported:
-- `PALMARES_PG_OWNER_CONN_STR` defaults to `PG_CONN_STR`, and in that shape there is no
-- `palmares_ro` to grant to. An unguarded GRANT would abort the boot transaction with
-- `role "palmares_ro" does not exist` and `applyPalmaresSchema` would `die` — so adding these two
-- statements for the roles' sake would have broken every deployment that has no roles yet.
--
-- The role is created by `admin apply-roles` (sql/050_roles.sql), which runs once per database as
-- the `dbsync` superuser. This file never creates it: a boot that could create a login role would
-- be a service that can grant itself rights.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'palmares_ro') THEN
    GRANT USAGE ON SCHEMA palmares TO palmares_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA palmares TO palmares_ro;
  END IF;
END $$;
