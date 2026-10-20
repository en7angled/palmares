-- db-sync shape fixture: the enums, domains and empty tables our views read.
--
-- GENERATED from the real preprod cardano-db-sync 13.7.1.0 schema (Experiment A's synced
-- database) with `pg_dump --schema-only -t <table>` plus the enum/domain DDL read out of
-- pg_type, then stripped of sequences, indexes, foreign keys and ownership. Column names,
-- types and NOT NULL are therefore the real ones, not a transcription of our column map --
-- which is the point: a seed row that would violate a real NOT NULL fails here, in CI,
-- instead of on preprod.
--
-- ponytail: this is a SHAPE fixture and nothing more. It has no rows, no constraints and no
-- indexes, so it cannot catch a view that is wrong about db-sync's *semantics* (which column
-- carries the authoritative value, whether a join can fan out). `sql/checks/*.sql` run against
-- the real preprod database is what catches that, and what catches this file drifting from a
-- db-sync upgrade.

-- Enum types, in db-sync's own label order (the order matters: ordinals leak into ORDER BY).
CREATE TYPE public.anchortype AS ENUM ('gov_action', 'drep', 'other', 'vote', 'committee_dereg', 'constitution');
CREATE TYPE public.govactiontype AS ENUM ('ParameterChange', 'HardForkInitiation', 'TreasuryWithdrawals', 'NoConfidence', 'NewCommittee', 'NewConstitution', 'InfoAction');
CREATE TYPE public.rewardtype AS ENUM ('leader', 'member', 'reserves', 'treasury', 'refund', 'proposal_refund');
CREATE TYPE public.scriptpurposetype AS ENUM ('spend', 'mint', 'cert', 'reward', 'vote', 'propose');
CREATE TYPE public.scripttype AS ENUM ('multisig', 'timelock', 'plutusV1', 'plutusV2', 'plutusV3');
CREATE TYPE public.syncstatetype AS ENUM ('lagging', 'following');
CREATE TYPE public.vote AS ENUM ('Yes', 'No', 'Abstain');
CREATE TYPE public.voterrole AS ENUM ('ConstitutionalCommittee', 'DRep', 'SPO');

-- Domains. word128type comes before outsum, which is defined over it.
CREATE DOMAIN public.word128type AS numeric(39,0);
CREATE DOMAIN public.addr29type AS bytea;
CREATE DOMAIN public.asset32type AS bytea;
CREATE DOMAIN public.hash28type AS bytea;
CREATE DOMAIN public.hash32type AS bytea;
CREATE DOMAIN public.int65type AS numeric(20,0);
CREATE DOMAIN public.lovelace AS numeric(20,0);
CREATE DOMAIN public.outsum AS public.word128type;
CREATE DOMAIN public.txindex AS smallint;
CREATE DOMAIN public.word31type AS integer;
CREATE DOMAIN public.word63type AS bigint;
CREATE DOMAIN public.word64type AS numeric(20,0);

-- The 35 tables our views read.

CREATE TABLE public.block (
    id bigint NOT NULL,
    hash public.hash32type NOT NULL,
    epoch_no public.word31type,
    slot_no public.word63type,
    epoch_slot_no public.word31type,
    block_no public.word31type,
    previous_id bigint,
    slot_leader_id bigint NOT NULL,
    size public.word31type NOT NULL,
    "time" timestamp without time zone NOT NULL,
    tx_count bigint NOT NULL,
    proto_major public.word31type NOT NULL,
    proto_minor public.word31type NOT NULL,
    vrf_key character varying,
    op_cert public.hash32type,
    op_cert_counter public.word63type
);

CREATE TABLE public.committee (
    id bigint NOT NULL,
    gov_action_proposal_id bigint,
    quorum_numerator bigint NOT NULL,
    quorum_denominator bigint NOT NULL
);

CREATE TABLE public.committee_de_registration (
    id bigint NOT NULL,
    tx_id bigint NOT NULL,
    cert_index integer NOT NULL,
    voting_anchor_id bigint,
    cold_key_id bigint NOT NULL
);

CREATE TABLE public.committee_hash (
    id bigint NOT NULL,
    raw public.hash28type NOT NULL,
    has_script boolean NOT NULL
);

CREATE TABLE public.committee_member (
    id bigint NOT NULL,
    committee_id bigint NOT NULL,
    committee_hash_id bigint NOT NULL,
    expiration_epoch public.word31type NOT NULL
);

CREATE TABLE public.committee_registration (
    id bigint NOT NULL,
    tx_id bigint NOT NULL,
    cert_index integer NOT NULL,
    cold_key_id bigint NOT NULL,
    hot_key_id bigint NOT NULL
);

CREATE TABLE public.constitution (
    id bigint NOT NULL,
    gov_action_proposal_id bigint,
    voting_anchor_id bigint NOT NULL,
    script_hash public.hash28type
);

CREATE TABLE public.delegation_vote (
    id bigint NOT NULL,
    addr_id bigint NOT NULL,
    cert_index integer NOT NULL,
    drep_hash_id bigint NOT NULL,
    tx_id bigint NOT NULL,
    redeemer_id bigint
);

CREATE TABLE public.drep_distr (
    id bigint NOT NULL,
    hash_id bigint NOT NULL,
    amount bigint NOT NULL,
    epoch_no public.word31type NOT NULL,
    active_until public.word31type
);

CREATE TABLE public.drep_hash (
    id bigint NOT NULL,
    raw public.hash28type,
    view character varying NOT NULL,
    has_script boolean NOT NULL
);

CREATE TABLE public.drep_registration (
    id bigint NOT NULL,
    tx_id bigint NOT NULL,
    cert_index integer NOT NULL,
    deposit bigint,
    drep_hash_id bigint NOT NULL,
    voting_anchor_id bigint
);

CREATE TABLE public.epoch_param (
    id bigint NOT NULL,
    epoch_no public.word31type NOT NULL,
    min_fee_a public.word31type NOT NULL,
    min_fee_b public.word31type NOT NULL,
    max_block_size public.word31type NOT NULL,
    max_tx_size public.word31type NOT NULL,
    max_bh_size public.word31type NOT NULL,
    key_deposit public.lovelace NOT NULL,
    pool_deposit public.lovelace NOT NULL,
    max_epoch public.word31type NOT NULL,
    optimal_pool_count public.word31type NOT NULL,
    influence double precision NOT NULL,
    monetary_expand_rate double precision NOT NULL,
    treasury_growth_rate double precision NOT NULL,
    decentralisation double precision NOT NULL,
    protocol_major public.word31type NOT NULL,
    protocol_minor public.word31type NOT NULL,
    min_utxo_value public.lovelace NOT NULL,
    min_pool_cost public.lovelace NOT NULL,
    nonce public.hash32type,
    cost_model_id bigint,
    price_mem double precision,
    price_step double precision,
    max_tx_ex_mem public.word64type,
    max_tx_ex_steps public.word64type,
    max_block_ex_mem public.word64type,
    max_block_ex_steps public.word64type,
    max_val_size public.word64type,
    collateral_percent public.word31type,
    max_collateral_inputs public.word31type,
    block_id bigint NOT NULL,
    extra_entropy public.hash32type,
    coins_per_utxo_size public.lovelace,
    pvt_motion_no_confidence double precision,
    pvt_committee_normal double precision,
    pvt_committee_no_confidence double precision,
    pvt_hard_fork_initiation double precision,
    dvt_motion_no_confidence double precision,
    dvt_committee_normal double precision,
    dvt_committee_no_confidence double precision,
    dvt_update_to_constitution double precision,
    dvt_hard_fork_initiation double precision,
    dvt_p_p_network_group double precision,
    dvt_p_p_economic_group double precision,
    dvt_p_p_technical_group double precision,
    dvt_p_p_gov_group double precision,
    dvt_treasury_withdrawal double precision,
    committee_min_size public.word64type,
    committee_max_term_length public.word64type,
    gov_action_lifetime public.word64type,
    gov_action_deposit public.word64type,
    drep_deposit public.word64type,
    drep_activity public.word64type,
    pvtpp_security_group double precision,
    min_fee_ref_script_cost_per_byte double precision
);

CREATE TABLE public.epoch_state (
    id bigint NOT NULL,
    committee_id bigint,
    no_confidence_id bigint,
    constitution_id bigint,
    epoch_no public.word31type NOT NULL
);

CREATE TABLE public.gov_action_proposal (
    id bigint NOT NULL,
    tx_id bigint NOT NULL,
    index bigint NOT NULL,
    prev_gov_action_proposal bigint,
    deposit public.lovelace NOT NULL,
    return_address bigint NOT NULL,
    expiration public.word31type,
    voting_anchor_id bigint,
    type public.govactiontype NOT NULL,
    description jsonb NOT NULL,
    param_proposal bigint,
    ratified_epoch public.word31type,
    enacted_epoch public.word31type,
    dropped_epoch public.word31type,
    expired_epoch public.word31type
);

CREATE TABLE public.meta (
    id bigint NOT NULL,
    start_time timestamp without time zone NOT NULL,
    network_name character varying NOT NULL,
    version character varying NOT NULL
);

CREATE TABLE public.off_chain_vote_author (
    id bigint NOT NULL,
    off_chain_vote_data_id bigint NOT NULL,
    name character varying,
    witness_algorithm character varying NOT NULL,
    public_key character varying NOT NULL,
    signature character varying NOT NULL,
    warning character varying
);

CREATE TABLE public.off_chain_vote_data (
    id bigint NOT NULL,
    voting_anchor_id bigint NOT NULL,
    hash bytea NOT NULL,
    "json" jsonb NOT NULL,
    bytes bytea NOT NULL,
    warning character varying,
    language character varying NOT NULL,
    comment character varying,
    is_valid boolean
);

CREATE TABLE public.off_chain_vote_drep_data (
    id bigint NOT NULL,
    off_chain_vote_data_id bigint NOT NULL,
    payment_address character varying,
    given_name character varying NOT NULL,
    objectives character varying,
    motivations character varying,
    qualifications character varying,
    image_url character varying,
    image_hash character varying
);

CREATE TABLE public.off_chain_vote_external_update (
    id bigint NOT NULL,
    off_chain_vote_data_id bigint NOT NULL,
    title character varying NOT NULL,
    uri character varying NOT NULL
);

CREATE TABLE public.off_chain_vote_fetch_error (
    id bigint NOT NULL,
    voting_anchor_id bigint NOT NULL,
    fetch_error character varying NOT NULL,
    fetch_time timestamp without time zone NOT NULL,
    retry_count public.word31type NOT NULL
);

CREATE TABLE public.off_chain_vote_gov_action_data (
    id bigint NOT NULL,
    off_chain_vote_data_id bigint NOT NULL,
    title character varying NOT NULL,
    abstract character varying NOT NULL,
    motivation character varying NOT NULL,
    rationale character varying NOT NULL
);

CREATE TABLE public.off_chain_vote_reference (
    id bigint NOT NULL,
    off_chain_vote_data_id bigint NOT NULL,
    label character varying NOT NULL,
    uri character varying NOT NULL,
    hash_digest character varying,
    hash_algorithm character varying
);

CREATE TABLE public.param_proposal (
    id bigint NOT NULL,
    epoch_no public.word31type,
    key public.hash28type,
    min_fee_a public.word64type,
    min_fee_b public.word64type,
    max_block_size public.word64type,
    max_tx_size public.word64type,
    max_bh_size public.word64type,
    key_deposit public.lovelace,
    pool_deposit public.lovelace,
    max_epoch public.word64type,
    optimal_pool_count public.word64type,
    influence double precision,
    monetary_expand_rate double precision,
    treasury_growth_rate double precision,
    decentralisation double precision,
    entropy public.hash32type,
    protocol_major public.word31type,
    protocol_minor public.word31type,
    min_utxo_value public.lovelace,
    min_pool_cost public.lovelace,
    cost_model_id bigint,
    price_mem double precision,
    price_step double precision,
    max_tx_ex_mem public.word64type,
    max_tx_ex_steps public.word64type,
    max_block_ex_mem public.word64type,
    max_block_ex_steps public.word64type,
    max_val_size public.word64type,
    collateral_percent public.word31type,
    max_collateral_inputs public.word31type,
    registered_tx_id bigint NOT NULL,
    coins_per_utxo_size public.lovelace,
    pvt_motion_no_confidence double precision,
    pvt_committee_normal double precision,
    pvt_committee_no_confidence double precision,
    pvt_hard_fork_initiation double precision,
    dvt_motion_no_confidence double precision,
    dvt_committee_normal double precision,
    dvt_committee_no_confidence double precision,
    dvt_update_to_constitution double precision,
    dvt_hard_fork_initiation double precision,
    dvt_p_p_network_group double precision,
    dvt_p_p_economic_group double precision,
    dvt_p_p_technical_group double precision,
    dvt_p_p_gov_group double precision,
    dvt_treasury_withdrawal double precision,
    committee_min_size public.word64type,
    committee_max_term_length public.word64type,
    gov_action_lifetime public.word64type,
    gov_action_deposit public.word64type,
    drep_deposit public.word64type,
    drep_activity public.word64type,
    pvtpp_security_group double precision,
    min_fee_ref_script_cost_per_byte double precision
);

CREATE TABLE public.pool_hash (
    id bigint NOT NULL,
    hash_raw public.hash28type NOT NULL,
    view character varying NOT NULL
);

CREATE TABLE public.pool_retire (
    id bigint NOT NULL,
    hash_id bigint NOT NULL,
    cert_index integer NOT NULL,
    announced_tx_id bigint NOT NULL,
    retiring_epoch public.word31type NOT NULL
);

CREATE TABLE public.pool_update (
    id bigint NOT NULL,
    hash_id bigint NOT NULL,
    cert_index integer NOT NULL,
    vrf_key_hash public.hash32type NOT NULL,
    pledge public.lovelace NOT NULL,
    active_epoch_no bigint NOT NULL,
    meta_id bigint,
    margin double precision NOT NULL,
    fixed_cost public.lovelace NOT NULL,
    registered_tx_id bigint NOT NULL,
    reward_addr_id bigint NOT NULL,
    deposit public.lovelace
);

CREATE TABLE public.reward_rest (
    addr_id bigint NOT NULL,
    type public.rewardtype NOT NULL,
    amount public.lovelace NOT NULL,
    spendable_epoch bigint NOT NULL,
    earned_epoch bigint GENERATED ALWAYS AS (
CASE
    WHEN (spendable_epoch >= 1) THEN (spendable_epoch - 1)
    ELSE (0)::bigint
END) STORED NOT NULL
);

CREATE TABLE public.schema_version (
    id bigint NOT NULL,
    stage_one bigint NOT NULL,
    stage_two bigint NOT NULL,
    stage_three bigint NOT NULL
);

CREATE TABLE public.stake_address (
    id bigint NOT NULL,
    hash_raw public.addr29type NOT NULL,
    view character varying NOT NULL,
    script_hash public.hash28type
);

CREATE TABLE public.stake_deregistration (
    id bigint NOT NULL,
    addr_id bigint NOT NULL,
    cert_index integer NOT NULL,
    epoch_no public.word31type NOT NULL,
    tx_id bigint NOT NULL,
    redeemer_id bigint
);

CREATE TABLE public.stake_registration (
    id bigint NOT NULL,
    addr_id bigint NOT NULL,
    cert_index integer NOT NULL,
    epoch_no public.word31type NOT NULL,
    tx_id bigint NOT NULL,
    deposit public.lovelace
);

CREATE TABLE public.treasury_withdrawal (
    id bigint NOT NULL,
    gov_action_proposal_id bigint NOT NULL,
    stake_address_id bigint NOT NULL,
    amount public.lovelace NOT NULL
);

CREATE TABLE public.tx (
    id bigint NOT NULL,
    hash public.hash32type NOT NULL,
    block_id bigint NOT NULL,
    block_index public.word31type NOT NULL,
    out_sum public.lovelace NOT NULL,
    fee public.lovelace NOT NULL,
    deposit bigint,
    size public.word31type NOT NULL,
    invalid_before public.word64type,
    invalid_hereafter public.word64type,
    valid_contract boolean NOT NULL,
    script_size public.word31type NOT NULL,
    treasury_donation public.lovelace DEFAULT 0 NOT NULL
);

CREATE TABLE public.voting_anchor (
    id bigint NOT NULL,
    url character varying NOT NULL,
    data_hash bytea NOT NULL,
    type public.anchortype NOT NULL,
    block_id bigint NOT NULL
);

CREATE TABLE public.voting_procedure (
    id bigint NOT NULL,
    tx_id bigint NOT NULL,
    index integer NOT NULL,
    gov_action_proposal_id bigint NOT NULL,
    voter_role public.voterrole NOT NULL,
    drep_voter bigint,
    pool_voter bigint,
    vote public.vote NOT NULL,
    voting_anchor_id bigint,
    committee_voter bigint,
    invalid bigint
);
