-- Roles, grants and search_path for the two schemas this product adds to db-sync's own database.
--
-- __This file is the control for co-locating our schemas in db-sync's database.__ ADR 0001 chose to
-- add `palmares` and `palmares_attest` to `cexplorer` rather than run a second database, because
-- every view we publish reads db-sync's tables and a cross-database join is not a thing. The price
-- of that choice is that our service's credentials sit inside the database db-sync writes, and this
-- file is what keeps them from being able to touch it. `scripts/check_roles.sh` asserts the
-- separation rather than assuming it.
--
-- Applied in AUTOCOMMIT by `admin apply-roles`, not by the service's boot DDL. Two reasons: it
-- needs the superuser db-sync owns, which the service deliberately does not have; and it runs once
-- per database rather than once per boot.
--
-- __No password appears here.__ `apply-roles` sets them from `PALMARES_OWNER_PASSWORD` and
-- `PALMARES_RO_PASSWORD`, passing each as a BOUND parameter and letting `format('%L')` quote it
-- server-side — a password spliced into DDL by a client is the one injection this file could have.
-- Roles created here therefore have no password until that step runs, and `NOLOGIN` would be wrong:
-- a role that cannot log in also cannot be granted a password without a second ALTER.

-- ---------------------------------------------------------------------------------------------
-- First, refuse to run as the wrong role.
--
-- The `ALTER DEFAULT PRIVILEGES` further down is scoped to the CURRENT role, because the role that
-- matters is whichever one db-sync's migrations create tables as — `dbsync` in the cluster,
-- `postgres` in `experiments/dbsync-preprod`. Run this file as any OTHER superuser and every
-- statement succeeds, the checks in `scripts/check_roles.sh` pass, and the default privilege covers
-- nothing: the next db-sync migration adds a table `palmares_ro` cannot read, and a view over it
-- fails at read time months later with a permission error that reads like a bug in the view.
--
-- So the assumption is asserted instead of documented. `public.voting_procedure` is from db-sync's
-- stage-2 migration, which is this file's stated precondition; if it does not exist the cast raises,
-- which is also correct — there is nothing to grant on yet.
DO $$
DECLARE
  owner_role name;
BEGIN
  SELECT pg_get_userbyid(relowner) INTO owner_role
    FROM pg_class WHERE oid = 'public.voting_procedure'::regclass;
  IF owner_role IS DISTINCT FROM current_user THEN
    RAISE EXCEPTION
      'apply-roles must connect as the role that owns db-sync''s tables (%), not as %', owner_role, current_user
      USING HINT = 'ALTER DEFAULT PRIVILEGES is scoped to the current role; under any other role it silently covers nothing.';
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------
-- The two roles.
--
-- `palmares_owner` owns our schemas and runs the boot DDL and the matview refresh.
-- `palmares_ro` is what the services connect as. Neither is a superuser, and neither may create
-- anything in `public` — that is db-sync's, and a migration of ours landing there would be a
-- schema change to somebody else's table.
--
-- `IF NOT EXISTS` is not available for CREATE ROLE, so each is guarded. Re-running this file must
-- be safe: it is applied by a Job that can be retried, and a failure halfway through is a database
-- with one role.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'palmares_owner') THEN
    CREATE ROLE palmares_owner LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'palmares_ro') THEN
    CREATE ROLE palmares_ro LOGIN;
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------
-- What the owner may do: create our schemas, and nothing in db-sync's.
GRANT CREATE ON DATABASE cexplorer TO palmares_owner;

CREATE SCHEMA IF NOT EXISTS palmares_attest AUTHORIZATION palmares_owner;

-- `palmares` itself is created by the service's boot DDL (sql/000_schema.sql), which DROPs and
-- recreates it every boot — so its owner is whoever runs that, which is `palmares_owner`. Setting
-- the authorization here too would be a second place that decides it.
ALTER SCHEMA palmares_attest OWNER TO palmares_owner;

-- The owner reads db-sync's tables (every view is built on them) and writes nothing there.
GRANT USAGE ON SCHEMA public TO palmares_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO palmares_owner;

-- ---------------------------------------------------------------------------------------------
-- What the read-only role may do: select, through our schemas and through db-sync's.
GRANT USAGE ON SCHEMA public TO palmares_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO palmares_ro;
GRANT USAGE ON SCHEMA palmares_attest TO palmares_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA palmares_attest TO palmares_ro;

-- `palmares` is dropped and recreated on every boot, so a grant made now would not survive. The
-- boot DDL grants it; what is set here is the DEFAULT, which a freshly created object inherits.
ALTER DEFAULT PRIVILEGES FOR ROLE palmares_owner IN SCHEMA palmares_attest
  GRANT SELECT ON TABLES TO palmares_ro;

-- __And again with no `FOR ROLE`, because nothing in this repository creates that table as
-- `palmares_owner`.__ `palmares_attest.chain_cursor` is attest-sync's, and all four places that
-- configure its connection — `defaultConnStr` in `src/exe/attest-sync/Main.hs`,
-- `Dockerfile.attest-sync`, `compose.yaml` and `.env.example` — say `user=postgres`, which in that
-- deployment is also the role db-sync's migrations run as, and therefore the current role here. The
-- line above covers a deployment that connects attest-sync as the owner; this one covers the four
-- that exist. Neither covers the other, and a default privilege is scoped to the role that CREATES
-- the object, so there is no single statement that covers both.
--
-- Without this, the failure is silent and accuses the wrong service. `GRANT ... ON ALL TABLES`
-- above resolves when it runs, so it covers nothing when `apply-roles` runs before attest-sync's
-- first boot — the normal order — and `palmares_ro` then cannot see the table at all, because
-- `information_schema.tables` lists only what the current role holds a privilege on: a missing
-- grant and an absent table are the same observation. `/status` then serves
-- `attest_lag_seconds: null`, which reads as "attest-sync has never run against this database".
--
-- The two statements together make the ORDER not matter, which is the point: the explicit GRANT
-- catches a table that already exists, this default catches one created afterwards.
ALTER DEFAULT PRIVILEGES IN SCHEMA palmares_attest GRANT SELECT ON TABLES TO palmares_ro;

-- __And the same for db-sync's own schema, which is the one that matters.__ db-sync adds tables in
-- its migrations, and a table added after this file ran would be invisible to `palmares_ro` — a
-- view over it would fail at read time with a permission error that looks like a bug in the view.
-- The default privilege is the only form that covers a table nobody has created yet.
--
-- No `FOR ROLE`, which means the CURRENT role — and that is deliberate rather than lazy. A default
-- privilege is scoped to the role that CREATES the object, so the one that matters is db-sync's own
-- role: `dbsync` in the cluster, `postgres` in `experiments/dbsync-preprod`. Naming either would be
-- wrong in the other place, and wrong in the silent direction. The guard above is what makes this
-- safe: it has already refused to run as anything but the role that owns db-sync's tables.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO palmares_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO palmares_owner;

-- ---------------------------------------------------------------------------------------------
-- search_path, so an unqualified name resolves the way every query in this codebase assumes.
--
-- Our own SQL qualifies everything (`palmares.vote`, `public.voting_procedure`), deliberately — a
-- query whose meaning depends on a session setting is a query that breaks when someone connects
-- with psql. This is for the ad-hoc case: a person at a prompt, and the checks in `sql/checks/`.
--
-- `palmares` first, then `palmares_attest`, then `public`: ours shadow db-sync's, which is the safe
-- direction. A name we define and db-sync later adds would otherwise change meaning under us.
ALTER ROLE palmares_ro SET search_path = palmares, palmares_attest, public;
ALTER ROLE palmares_owner SET search_path = palmares, palmares_attest, public;

-- ---------------------------------------------------------------------------------------------
-- What neither role may do, stated as revocations rather than left to the default.
--
-- PUBLIC holds CREATE on `public` in PostgreSQL 14 and earlier and not in 15+; this database is 17,
-- so the revoke is a no-op today and is kept because it costs nothing and the day somebody restores
-- a dump into an older server is the day it matters.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM palmares_ro;
REVOKE CREATE ON SCHEMA public FROM palmares_owner;
REVOKE ALL ON DATABASE cexplorer FROM PUBLIC;
GRANT CONNECT ON DATABASE cexplorer TO palmares_owner, palmares_ro;
