-- The palmares schema itself. Exactly two statements, and deliberately nothing else.
--
-- DROP ... CASCADE first is what makes the whole bootstrap idempotent: every object in here is
-- a view or a matview derived from db-sync, so there is no state to preserve and re-creating
-- from scratch is both the simplest and the only safe migration story.
--
-- This file must NEVER mention `palmares_attest`: that schema holds attest-sync's own projected
-- tables, which `persistent` creates and migrates. Dropping it here would delete chain-sync
-- state that takes a full re-sync to rebuild.
DROP SCHEMA IF EXISTS palmares CASCADE;
CREATE SCHEMA palmares;
