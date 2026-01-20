-- ============================================================================
-- YETO (Yemen Economic Transparency Observatory)
-- PostgreSQL Schema (FINAL – Jan 2026)
-- Coverage: 2010-01-01 → Present
--
-- Data model principles:
--  - Evidence-first: every fact must be traceable to a source (SRC-ID) and an ingestion run.
--  - Versioning: "As-Of" mode supported via vintage_date + revision_no.
--  - Split-system support: store regime_tag without forced aggregation.
--  - Bilingual parity: EN/AR content stored natively.
--  - Auditability: every governance/agent action is logged.
-- ============================================================================

BEGIN;


-- Extensions (enable in RDS parameter group as needed)
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;
-- pgvector (optional but recommended for semantic search)
CREATE EXTENSION IF NOT EXISTS vector;
-- Create dedicated schema namespace for YETO objects
CREATE SCHEMA IF NOT EXISTS yeto;
SET search_path = yeto, public;


-- ---------------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------------

CREATE TYPE lang_code AS ENUM ('EN','AR');

CREATE TYPE regime_tag AS ENUM (
  'NATIONAL_UNIFIED',
  'IRG_ADEN',
  'DFA_SANAA',
  'MIXED',
  'NOT_APPLICABLE'
);

CREATE TYPE source_tier AS ENUM ('T1','T2','T3','UNKNOWN');

CREATE TYPE source_status AS ENUM ('ACTIVE','INACTIVE','PENDING_REVIEW','NEEDS_KEY','BLOCKED','DEPRECATED');

CREATE TYPE ingestion_run_status AS ENUM ('RUNNING','SUCCESS','FAILED','PARTIAL');

CREATE TYPE gap_ticket_status AS ENUM ('OPEN','IN_PROGRESS','RESOLVED','WONT_FIX');

CREATE TYPE severity_level AS ENUM ('LOW','MEDIUM','HIGH','CRITICAL');

CREATE TYPE content_visibility AS ENUM ('PUBLIC','PREMIUM','INTERNAL');

CREATE TYPE content_status AS ENUM ('DRAFT','UNDER_REVIEW','PUBLISHED','RETRACTED','ARCHIVED');

CREATE TYPE approval_stage AS ENUM (
  'DRAFTING',
  'EVIDENCE',
  'CONSISTENCY',
  'SAFETY',
  'AR_COPY',
  'EN_COPY',
  'STANDARDS',
  'FINAL_APPROVAL'
);

CREATE TYPE approval_result AS ENUM ('PASS','FAIL','NEEDS_HUMAN','SKIPPED');

CREATE TYPE doc_kind AS ENUM (
  'REPORT',
  'BULLETIN',
  'DATASET_DOC',
  'POLICY',
  'PRESS_RELEASE',
  'ACADEMIC',
  'NEWS',
  'OTHER'
);

CREATE TYPE geo_type AS ENUM ('COUNTRY','GOVERNORATE','DISTRICT','CITY','PORT','CUSTOM');

CREATE TYPE indicator_frequency AS ENUM ('DAILY','WEEKLY','MONTHLY','QUARTERLY','ANNUAL','IRREGULAR');

CREATE TYPE data_value_kind AS ENUM ('NUMERIC','TEXT','JSON');

CREATE TYPE stakeholder_category AS ENUM (
  'GOVERNMENT',
  'INTERNATIONAL_ORG',
  'DONOR',
  'FINANCIAL_INSTITUTION',
  'NGO',
  'ACADEMIA',
  'MEDIA',
  'PRIVATE_SECTOR',
  'CITIZEN',
  'OTHER'
);

CREATE TYPE publication_job_status AS ENUM ('SCHEDULED','RUNNING','BLOCKED','FAILED','PUBLISHED');

CREATE TYPE contradiction_status AS ENUM ('OPEN','RESOLVED','DISMISSED');

-- ---------------------------------------------------------------------------
-- COMMON HELPERS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- GEOGRAPHY
-- ---------------------------------------------------------------------------

CREATE TABLE geo (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  geo_type geo_type NOT NULL,
  code text NOT NULL,
  name_en text NOT NULL,
  name_ar text,
  parent_id uuid REFERENCES geo(id) ON DELETE SET NULL,
  bbox jsonb,
  geom_geojson jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (geo_type, code)
);

CREATE TRIGGER trg_geo_updated_at
BEFORE UPDATE ON geo
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- AUTH / RBAC
-- ---------------------------------------------------------------------------

CREATE TABLE user_account (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext UNIQUE NOT NULL,
  display_name text,
  password_hash text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_user_account_updated_at
BEFORE UPDATE ON user_account
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE role (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  role_key text UNIQUE NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE permission (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  permission_key text UNIQUE NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE role_permission (
  role_id uuid NOT NULL REFERENCES role(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES permission(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_role (
  user_id uuid NOT NULL REFERENCES user_account(id) ON DELETE CASCADE,
  role_id uuid NOT NULL REFERENCES role(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);

-- ---------------------------------------------------------------------------
-- SUBSCRIPTIONS (feature gating)
-- ---------------------------------------------------------------------------

CREATE TABLE subscription_plan (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_key text UNIQUE NOT NULL,
  name_en text NOT NULL,
  name_ar text,
  features jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_public boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_subscription_plan_updated_at
BEFORE UPDATE ON subscription_plan
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE subscription (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES user_account(id) ON DELETE CASCADE,
  plan_id uuid NOT NULL REFERENCES subscription_plan(id),
  status text NOT NULL DEFAULT 'ACTIVE',
  started_at timestamptz NOT NULL DEFAULT NOW(),
  ends_at timestamptz,
  external_billing_ref text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_subscription_updated_at
BEFORE UPDATE ON subscription
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- SOURCE REGISTRY (225+ sources)
-- NOTE: columns aligned to sources_seed_225.csv for direct COPY.
-- ---------------------------------------------------------------------------

CREATE TABLE source (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  src_id text UNIQUE NOT NULL,                 -- e.g., SRC-001
  src_numeric_id integer,                      -- optional
  name_en text NOT NULL,
  name_ar text,
  category text,
  tier source_tier NOT NULL,
  institution text,
  url text,
  url_raw text,
  access_method text,
  update_frequency text,
  cadence indicator_frequency,
  license text,
  reliability_score text,
  geographic_coverage text,
  coverage text,
  typical_lag_days integer,
  typical_lag_text text,
  auth text,
  data_fields text,
  ingestion_method text,
  yeto_usage text,
  yeto_module text,
  granularity_caveats text,
  notes text,
  tags text,
  origin text,
  status source_status NOT NULL DEFAULT 'ACTIVE',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_source_tier ON source(tier);
CREATE INDEX idx_source_status ON source(status);
CREATE INDEX idx_source_active ON source(active);
CREATE INDEX idx_source_cadence ON source(cadence);

CREATE TRIGGER trg_source_updated_at
BEFORE UPDATE ON source
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE source_endpoint (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  endpoint_name text NOT NULL,
  endpoint_url text NOT NULL,
  method text NOT NULL DEFAULT 'GET',
  headers jsonb,
  query_defaults jsonb,
  auth_required boolean NOT NULL DEFAULT false,
  cadence_hint text,
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_source_endpoint_source ON source_endpoint(source_id);

-- ---------------------------------------------------------------------------
-- INGESTION / RAW STORAGE
-- ---------------------------------------------------------------------------

CREATE TABLE ingestion_run (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES source(id) ON DELETE CASCADE,
  run_started_at timestamptz NOT NULL DEFAULT NOW(),
  run_ended_at timestamptz,
  status ingestion_run_status NOT NULL,
  http_status integer,
  error_summary text,
  error_detail text,
  retry_count integer NOT NULL DEFAULT 0,
  rows_ingested bigint,
  objects_written integer,
  metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  run_context jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ingestion_run_source ON ingestion_run(source_id);
CREATE INDEX idx_ingestion_run_status ON ingestion_run(status);
CREATE INDEX idx_ingestion_run_started ON ingestion_run(run_started_at DESC);

CREATE TABLE raw_object (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ingestion_run_id uuid NOT NULL REFERENCES ingestion_run(id) ON DELETE CASCADE,
  object_kind text NOT NULL,                   -- api_json, csv, xlsx, pdf, html, geojson, etc.
  storage_uri text NOT NULL,                   -- s3://bucket/key or local path
  sha256 text NOT NULL,
  bytes bigint,
  content_type text,
  extracted_text text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (ingestion_run_id, sha256)
);

CREATE INDEX idx_raw_object_run ON raw_object(ingestion_run_id);

-- ---------------------------------------------------------------------------
-- DATASET / INDICATORS / SERIES / OBSERVATIONS
-- ---------------------------------------------------------------------------

CREATE TABLE dataset (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_key text UNIQUE NOT NULL,
  name_en text NOT NULL,
  name_ar text,
  description_en text,
  description_ar text,
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  sector text,
  tags text[],
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_dataset_updated_at
BEFORE UPDATE ON dataset
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE dataset_version (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_id uuid NOT NULL REFERENCES dataset(id) ON DELETE CASCADE,
  version_label text NOT NULL,
  published_at timestamptz,
  effective_from date,
  effective_to date,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(dataset_id, version_label)
);

CREATE INDEX idx_dataset_version_dataset ON dataset_version(dataset_id);

CREATE TABLE indicator (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  indicator_code text UNIQUE NOT NULL,         -- internal YETO code
  name_en text NOT NULL,
  name_ar text,
  description_en text,
  description_ar text,
  unit text,
  decimals integer NOT NULL DEFAULT 2,
  frequency indicator_frequency NOT NULL,
  category text,
  methodology_en text,
  methodology_ar text,
  tags text[],
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_indicator_updated_at
BEFORE UPDATE ON indicator
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE series (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  indicator_id uuid NOT NULL REFERENCES indicator(id) ON DELETE CASCADE,
  geo_id uuid REFERENCES geo(id) ON DELETE SET NULL,
  regime regime_tag NOT NULL DEFAULT 'NOT_APPLICABLE',
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  dataset_id uuid REFERENCES dataset(id) ON DELETE SET NULL,
  external_series_code text,
  frequency indicator_frequency NOT NULL,
  value_kind data_value_kind NOT NULL DEFAULT 'NUMERIC',
  currency text,
  unit_override text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (indicator_id, geo_id, regime, source_id, external_series_code)
);

CREATE INDEX idx_series_indicator ON series(indicator_id);
CREATE INDEX idx_series_geo ON series(geo_id);
CREATE INDEX idx_series_regime ON series(regime);

CREATE TRIGGER trg_series_updated_at
BEFORE UPDATE ON series
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE observation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES series(id) ON DELETE CASCADE,
  obs_date date NOT NULL,
  period_start date,
  period_end date,
  value_numeric numeric,
  value_text text,
  value_json jsonb,
  is_estimate boolean NOT NULL DEFAULT false,
  confidence numeric,                          -- 0..1
  source_id uuid NOT NULL REFERENCES source(id) ON DELETE RESTRICT,
  ingestion_run_id uuid NOT NULL REFERENCES ingestion_run(id) ON DELETE RESTRICT,
  vintage_date date NOT NULL DEFAULT CURRENT_DATE,
  revision_no integer NOT NULL DEFAULT 0,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (series_id, obs_date, vintage_date, revision_no)
);

CREATE INDEX idx_observation_series_date ON observation(series_id, obs_date);
CREATE INDEX idx_observation_vintage ON observation(vintage_date);
CREATE INDEX idx_observation_source ON observation(source_id);

-- Daily calendar anchor (for "every day since 2010" timelines)
CREATE TABLE calendar_day (
  day date PRIMARY KEY,
  iso_year integer NOT NULL,
  iso_week integer NOT NULL,
  month integer NOT NULL,
  quarter integer NOT NULL,
  day_of_week integer NOT NULL,
  is_weekend boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- DOCUMENT LIBRARY / RESEARCH HUB
-- ---------------------------------------------------------------------------

CREATE TABLE document (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_kind doc_kind NOT NULL,
  title_en text NOT NULL,
  title_ar text,
  publisher text,
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  published_at date,
  retrieved_at timestamptz NOT NULL DEFAULT NOW(),
  url text,
  storage_uri text,
  language_original lang_code,
  license text,
  sha256 text,
  summary_en text,
  summary_ar text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_document_source ON document(source_id);
CREATE INDEX idx_document_published ON document(published_at);

CREATE TRIGGER trg_document_updated_at
BEFORE UPDATE ON document
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE document_text_chunk (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES document(id) ON DELETE CASCADE,
  chunk_index integer NOT NULL,
  page_start integer,
  page_end integer,
  text_en text,
  text_ar text,
  embedding vector(1536),
  citations jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (document_id, chunk_index)
);

CREATE INDEX idx_doc_chunk_doc ON document_text_chunk(document_id);

-- ---------------------------------------------------------------------------
-- EVENTS (timeline)
-- ---------------------------------------------------------------------------

CREATE TABLE event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type text NOT NULL,
  title_en text NOT NULL,
  title_ar text,
  event_date date NOT NULL,
  geo_id uuid REFERENCES geo(id) ON DELETE SET NULL,
  description_en text,
  description_ar text,
  severity severity_level NOT NULL DEFAULT 'MEDIUM',
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  citations jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_event_date ON event(event_date);
CREATE INDEX idx_event_type ON event(event_type);

CREATE TRIGGER trg_event_updated_at
BEFORE UPDATE ON event
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- CONTENT (reports, updates, dashboard narratives) + evidence
-- ---------------------------------------------------------------------------

CREATE TABLE content_item (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_type text NOT NULL,
  title_en text NOT NULL,
  title_ar text,
  body_en text,
  body_ar text,
  visibility content_visibility NOT NULL DEFAULT 'PUBLIC',
  status content_status NOT NULL DEFAULT 'DRAFT',
  period_start date,
  period_end date,
  evidence_set_hash text,
  created_by uuid REFERENCES user_account(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  published_at timestamptz
);

CREATE INDEX idx_content_status ON content_item(status);
CREATE INDEX idx_content_visibility ON content_item(visibility);
CREATE INDEX idx_content_published ON content_item(published_at DESC);

CREATE TRIGGER trg_content_item_updated_at
BEFORE UPDATE ON content_item
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE content_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_item_id uuid NOT NULL REFERENCES content_item(id) ON DELETE CASCADE,
  claim_text text NOT NULL,
  lang lang_code NOT NULL,
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  document_id uuid REFERENCES document(id) ON DELETE SET NULL,
  url text,
  page_ref text,
  extracted_quote text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_content_evidence_item ON content_evidence(content_item_id);

-- ---------------------------------------------------------------------------
-- MULTI-AGENT APPROVAL ENGINE
-- ---------------------------------------------------------------------------

CREATE TABLE agent (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_key text UNIQUE NOT NULL,
  name_en text NOT NULL,
  name_ar text,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE agent_run (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id uuid NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
  content_item_id uuid NOT NULL REFERENCES content_item(id) ON DELETE CASCADE,
  stage approval_stage NOT NULL,
  result approval_result NOT NULL,
  score numeric,
  notes text,
  output jsonb NOT NULL DEFAULT '{}'::jsonb,
  run_started_at timestamptz NOT NULL DEFAULT NOW(),
  run_ended_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_agent_run_content ON agent_run(content_item_id);
CREATE INDEX idx_agent_run_stage ON agent_run(stage);

CREATE TABLE uniqueness_check (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_item_id uuid NOT NULL REFERENCES content_item(id) ON DELETE CASCADE,
  compared_to jsonb NOT NULL DEFAULT '[]'::jsonb,
  similarity_score numeric NOT NULL,
  method text NOT NULL,
  pass boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE approval_policy (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_type text UNIQUE NOT NULL,
  approval_mode text NOT NULL DEFAULT 'AI_ONLY',
  min_citations integer NOT NULL DEFAULT 3,
  min_evidence_coverage numeric NOT NULL DEFAULT 0.95,
  max_similarity_score numeric NOT NULL DEFAULT 0.25,
  max_variance_flag numeric NOT NULL DEFAULT 0.15,
  rules jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_approval_policy_updated_at
BEFORE UPDATE ON approval_policy
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ---------------------------------------------------------------------------
-- COMPLIANCE / SANCTIONS SCREENING (safe-by-design, audit-logged)
-- ---------------------------------------------------------------------------

CREATE TABLE compliance_list (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_en text NOT NULL,
  name_ar text,
  list_type text NOT NULL, -- SANCTIONS | WATCHLIST | OTHER
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  license text,
  url text,
  last_refreshed_at timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_compliance_list_type ON compliance_list(list_type);

CREATE TRIGGER trg_compliance_list_updated_at
BEFORE UPDATE ON compliance_list
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE compliance_entity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compliance_list_id uuid NOT NULL REFERENCES compliance_list(id) ON DELETE CASCADE,
  entity_name text NOT NULL,
  entity_name_ar text,
  aliases text[] NOT NULL DEFAULT ARRAY[]::text[],
  entity_type text,
  country text,
  identifiers jsonb NOT NULL DEFAULT '{}'::jsonb,
  risk_notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_compliance_entity_list ON compliance_entity(compliance_list_id);
CREATE INDEX idx_compliance_entity_name ON compliance_entity(entity_name);

CREATE TRIGGER trg_compliance_entity_updated_at
BEFORE UPDATE ON compliance_entity
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE screening_event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by uuid REFERENCES user_account(id) ON DELETE SET NULL,
  query_text text NOT NULL,
  query_params jsonb NOT NULL DEFAULT '{}'::jsonb,
  results_summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_screening_event_time ON screening_event(created_at DESC);


-- ---------------------------------------------------------------------------
-- GOVERNANCE: GAPS, CORRECTIONS, AUDIT
-- ---------------------------------------------------------------------------

CREATE TABLE gap_ticket (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gap_type text NOT NULL,
  title text NOT NULL,
  description text,
  severity severity_level NOT NULL DEFAULT 'MEDIUM',
  status gap_ticket_status NOT NULL DEFAULT 'OPEN',
  related_source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  related_indicator_id uuid REFERENCES indicator(id) ON DELETE SET NULL,
  related_series_id uuid REFERENCES series(id) ON DELETE SET NULL,
  related_module text,
  opened_by uuid REFERENCES user_account(id) ON DELETE SET NULL,
  opened_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  resolved_at timestamptz,
  resolution_notes text
);

CREATE INDEX idx_gap_ticket_status ON gap_ticket(status);
CREATE INDEX idx_gap_ticket_severity ON gap_ticket(severity);

CREATE TRIGGER trg_gap_ticket_updated_at
BEFORE UPDATE ON gap_ticket
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE correction_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  field_name text NOT NULL,
  old_value text,
  new_value text,
  reason text,
  corrected_by uuid REFERENCES user_account(id) ON DELETE SET NULL,
  corrected_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id uuid REFERENCES user_account(id) ON DELETE SET NULL,
  actor_type text NOT NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_log_entity ON audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_log_time ON audit_log(created_at DESC);


-- ---------------------------------------------------------------------------
-- PROVENANCE LEDGER + CONTRADICTIONS (evidence transformations & disagreements)
-- ---------------------------------------------------------------------------

CREATE TABLE provenance_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,                         -- INGEST | NORMALIZE | TRANSFORM | AGGREGATE | DERIVE | VALIDATE | PUBLISH
  input_refs jsonb NOT NULL DEFAULT '{}'::jsonb, -- {sources:[...], datasets:[...], documents:[...], series:[...], observations:[...]}
  output_refs jsonb NOT NULL DEFAULT '{}'::jsonb,
  formula text,
  parameters jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_ids text[] NOT NULL DEFAULT ARRAY[]::text[],     -- SRC-IDs involved
  ingestion_run_id uuid REFERENCES ingestion_run(id) ON DELETE SET NULL,
  agent_run_id uuid REFERENCES agent_run(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_prov_action ON provenance_ledger(action);
CREATE INDEX idx_prov_ingestion ON provenance_ledger(ingestion_run_id);
CREATE INDEX idx_prov_agent_run ON provenance_ledger(agent_run_id);

CREATE TABLE contradiction (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid REFERENCES series(id) ON DELETE SET NULL,
  observation_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  description text NOT NULL,
  detected_by_agent uuid REFERENCES agent(id) ON DELETE SET NULL,
  detected_at timestamptz NOT NULL DEFAULT NOW(),
  status contradiction_status NOT NULL DEFAULT 'OPEN',
  resolution_summary text,
  resolved_at timestamptz,
  resolved_by uuid REFERENCES user_account(id) ON DELETE SET NULL
);

CREATE INDEX idx_contradiction_status ON contradiction(status);
CREATE INDEX idx_contradiction_series ON contradiction(series_id);

CREATE TABLE contradiction_resolution (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contradiction_id uuid NOT NULL REFERENCES contradiction(id) ON DELETE CASCADE,
  resolution text NOT NULL,
  resolved_by uuid REFERENCES user_account(id) ON DELETE SET NULL,
  resolved_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_contradiction_resolution_contradiction ON contradiction_resolution(contradiction_id);

-- ---------------------------------------------------------------------------
-- GLOSSARY + UI STRINGS (BILINGUAL)
-- ---------------------------------------------------------------------------

CREATE TABLE glossary_term (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  term_key text UNIQUE NOT NULL,
  term_en text NOT NULL,
  term_ar text,
  definition_en text,
  definition_ar text,
  notes text,
  tags text[],
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_glossary_term_updated_at
BEFORE UPDATE ON glossary_term
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE ui_string (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  string_key text UNIQUE NOT NULL,
  text_en text NOT NULL,
  text_ar text,
  context text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_ui_string_updated_at
BEFORE UPDATE ON ui_string
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ---------------------------------------------------------------------------
-- CANONICAL NAMES REGISTRY (EN/AR term standardization & aliasing)
-- ---------------------------------------------------------------------------

CREATE TABLE canonical_names_registry (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_key text UNIQUE NOT NULL,   -- e.g., FX_RESERVES, CBY_ADEN, CBY_SANAA
  entity_type text,                    -- INDICATOR | INSTITUTION | GEO | PROGRAM | OTHER
  name_en text NOT NULL,
  name_ar text,
  aliases_en text[] NOT NULL DEFAULT ARRAY[]::text[],
  aliases_ar text[] NOT NULL DEFAULT ARRAY[]::text[],
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_canonical_names_entity_type ON canonical_names_registry(entity_type);

CREATE TRIGGER trg_canonical_names_updated_at
BEFORE UPDATE ON canonical_names_registry
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- STAKEHOLDER REGISTRY
-- ---------------------------------------------------------------------------

CREATE TABLE stakeholder (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_en text NOT NULL,
  name_ar text,
  category stakeholder_category NOT NULL,
  regime regime_tag NOT NULL DEFAULT 'NOT_APPLICABLE',
  what_they_control text,
  incentives text,
  constraints text,
  typical_decision_horizon text,
  indicators_they_watch text,
  thresholds_that_move_decisions text,
  preferred_outputs text,
  contact_channel text,           -- organization channel only (no PII)
  website_url text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stakeholder_category ON stakeholder(category);

CREATE TRIGGER trg_stakeholder_updated_at
BEFORE UPDATE ON stakeholder
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ---------------------------------------------------------------------------
-- PROJECTS (optional – for 3W / aid programming integration)
-- ---------------------------------------------------------------------------

CREATE TABLE project (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_code text,                          -- external id if available (e.g., OCHA 3W)
  name_en text NOT NULL,
  name_ar text,
  sector text,
  sub_sector text,
  donor_stakeholder_id uuid REFERENCES stakeholder(id) ON DELETE SET NULL,
  implementer_stakeholder_id uuid REFERENCES stakeholder(id) ON DELETE SET NULL,
  start_date date,
  end_date date,
  budget_amount numeric,
  budget_currency text,
  geo_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  source_id uuid REFERENCES source(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'ACTIVE',
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_project_sector ON project(sector);
CREATE INDEX idx_project_dates ON project(start_date, end_date);

CREATE TRIGGER trg_project_updated_at
BEFORE UPDATE ON project
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ---------------------------------------------------------------------------
-- PUBLICATION STREAMS (scheduled reporting)
-- ---------------------------------------------------------------------------

CREATE TABLE publication_stream (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stream_key text UNIQUE NOT NULL,
  name_en text NOT NULL,
  name_ar text,
  cadence_cron text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  default_visibility content_visibility NOT NULL DEFAULT 'PUBLIC',
  default_languages lang_code[] NOT NULL DEFAULT ARRAY['EN','AR']::lang_code[],
  prompt_template text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_publication_stream_updated_at
BEFORE UPDATE ON publication_stream
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE publication_job (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stream_id uuid NOT NULL REFERENCES publication_stream(id) ON DELETE CASCADE,
  period_start date NOT NULL,
  period_end date NOT NULL,
  scheduled_for timestamptz NOT NULL,
  status publication_job_status NOT NULL DEFAULT 'SCHEDULED',
  content_item_id uuid REFERENCES content_item(id) ON DELETE SET NULL,
  run_log jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_publication_job_stream ON publication_job(stream_id);
CREATE INDEX idx_publication_job_status ON publication_job(status);

CREATE TRIGGER trg_publication_job_updated_at
BEFORE UPDATE ON publication_job
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
