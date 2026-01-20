-- ============================================================================
-- YETO Seed Data (FINAL – Jan 2026)
-- Compatible with: yeto_postgres_schema_master.sql
--
-- Usage:
--   psql "$DATABASE_URL" -f db/schema.sql
--   psql "$DATABASE_URL" -f db/seed.sql
--
-- IMPORTANT:
--  - This seed does NOT fabricate Yemen statistics. It only inserts system metadata
--    and the 225-source registry from CSV.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

SET search_path = yeto, public;

-- ---------------------------------------------------------------------------
-- GEO (minimal)
-- ---------------------------------------------------------------------------
INSERT INTO geo (geo_type, code, name_en, name_ar)
VALUES ('COUNTRY','YEM','Yemen','اليمن')
ON CONFLICT (geo_type, code) DO NOTHING;


-- ---------------------------------------------------------------------------
-- Calendar Day Index (2010-01-01 → 2050-12-31)
-- Used for completeness, gap detection, and daily timeline navigation.
-- ---------------------------------------------------------------------------
INSERT INTO calendar_day (day, iso_year, iso_week, month, quarter, day_of_week, is_weekend)
SELECT
  d::date AS day,
  EXTRACT(ISOYEAR FROM d)::int AS iso_year,
  EXTRACT(WEEK FROM d)::int AS iso_week,
  EXTRACT(MONTH FROM d)::int AS month,
  EXTRACT(QUARTER FROM d)::int AS quarter,
  EXTRACT(ISODOW FROM d)::int AS day_of_week,
  (EXTRACT(ISODOW FROM d) IN (6,7)) AS is_weekend
FROM generate_series('2010-01-01'::date, '2050-12-31'::date, interval '1 day') AS d
ON CONFLICT (day) DO NOTHING;

-- ---------------------------------------------------------------------------
-- RBAC Roles
-- ---------------------------------------------------------------------------
INSERT INTO role (role_key, description) VALUES
  ('public', 'Unauthenticated public visitor (read-only, rate-limited).'),
  ('registered', 'Registered user (basic access).'),
  ('pro', 'Professional subscriber (advanced analytics, exports, API).'),
  ('enterprise', 'Institutional subscriber (team features, bulk exports, advanced API).'),
  ('partner_contributor', 'Verified partner contributor (submit sources/evidence; no PII).'),
  ('editor', 'Editorial reviewer (edit/publish content subject to governance pipeline).'),
  ('data_steward', 'Data steward (manage source registry, ingestion, QA, gap tickets).'),
  ('compliance_officer', 'Compliance analyst (sanctions/compliance module).'),
  ('admin', 'System administrator (RBAC, config, governance dashboard).'),
  ('owner', 'Owner override (OWNER_REVIEW_MODE on staging only).')
ON CONFLICT (role_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Subscription Plans (feature flags enforced in both backend and UI)
-- ---------------------------------------------------------------------------
INSERT INTO subscription_plan (plan_key, name_en, name_ar, features, is_public)
VALUES
  ('public', 'Public', 'عام',
    '{"dashboards":true,"research":true,"downloads":{"csv":false,"xlsx":false,"pdf":false,"png":false,"svg":false,"json":false},"api":{"enabled":false},"alerts":{"enabled":false},"workspace":false,"scenario_sim":false,"assistant":false}'::jsonb,
    true),
  ('registered', 'Registered', 'مسجل',
    '{"dashboards":true,"research":true,"downloads":{"csv":true,"xlsx":false,"pdf":false,"png":false,"svg":false,"json":false},"api":{"enabled":false},"alerts":{"enabled":true,"max":5},"workspace":true,"scenario_sim":false,"assistant":false}'::jsonb,
    true),
  ('pro', 'Pro', 'احترافي',
    '{"dashboards":true,"research":true,"downloads":{"csv":true,"xlsx":true,"pdf":true,"png":true,"svg":true,"json":true},"api":{"enabled":true,"daily_limit":5000},"alerts":{"enabled":true,"max":50},"workspace":true,"scenario_sim":true,"assistant":true}'::jsonb,
    false),
  ('enterprise', 'Enterprise', 'مؤسسي',
    '{"dashboards":true,"research":true,"downloads":{"csv":true,"xlsx":true,"pdf":true,"png":true,"svg":true,"json":true},"api":{"enabled":true,"daily_limit":100000},"alerts":{"enabled":true,"max":500},"workspace":true,"scenario_sim":true,"assistant":true,"team":true,"sso":true,"scheduled_exports":true}'::jsonb,
    false)
ON CONFLICT (plan_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Agents (8-stage approval pipeline)
-- ---------------------------------------------------------------------------
INSERT INTO agent (agent_key, name_en, name_ar, description)
VALUES
  ('AGENT_1_DRAFTING','Drafting Agent','وكيل الصياغة','Drafts structured content from evidence (no uncited claims).'),
  ('AGENT_2_EVIDENCE','Evidence Agent','وكيل الاستدلال','Validates every claim against citations; builds evidence pack.'),
  ('AGENT_3_CONSISTENCY','Consistency Agent','وكيل الاتساق','Triangulates across peer sources; flags variance/outliers.'),
  ('AGENT_4_SAFETY','Safety Agent','وكيل السلامة','Applies Do-No-Harm + privacy + sanctions/compliance rules.'),
  ('AGENT_5_AR_EDITOR','Arabic Editor','محرر العربية','Ensures Arabic (RTL) quality, glossary compliance, professional tone.'),
  ('AGENT_6_EN_EDITOR','English Editor','محرر الإنجليزية','Ensures English quality, consistent voice, professional tone.'),
  ('AGENT_7_STANDARDS','Standards & Branding','وكيل المعايير','Enforces UI/content standards: no placeholders, no vendor logos, no AI vendor names.'),
  ('AGENT_8_FINAL_APPROVAL','Final Approver','وكيل الاعتماد النهائي','Final gate: publishes only if all prior stages pass.')
ON CONFLICT (agent_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Default publication streams (cadence is configurable)
-- ---------------------------------------------------------------------------
INSERT INTO publication_stream (stream_key, name_en, name_ar, cadence_cron, is_active, default_visibility, default_languages)
VALUES
  ('daily_brief','Daily Brief','الإحاطة اليومية','0 6 * * *', true, 'PUBLIC', ARRAY['EN','AR']::lang_code[]),
  ('weekly_update','Weekly Update','التحديث الأسبوعي','0 7 * * 1', true, 'PUBLIC', ARRAY['EN','AR']::lang_code[]),
  ('monthly_economic_update','Monthly Economic Update','التقرير الاقتصادي الشهري','0 8 3 * *', true, 'PREMIUM', ARRAY['EN','AR']::lang_code[]),
  ('quarterly_review','Quarterly Review','المراجعة الفصلية','0 8 10 */3 *', true, 'PREMIUM', ARRAY['EN','AR']::lang_code[]),
  ('annual_review','Annual Review','التقرير السنوي','0 9 15 1 *', true, 'PREMIUM', ARRAY['EN','AR']::lang_code[])
ON CONFLICT (stream_key) DO NOTHING;

COMMIT;

-- ---------------------------------------------------------------------------
-- Load the 225+ Source Registry (CSV)
-- ---------------------------------------------------------------------------
-- Place the CSV at: db/seeds/sources_seed_225.csv
-- Then run this seed script.

\copy yeto.source (
  src_id, src_numeric_id, name_en, name_ar, category, tier, institution, url, url_raw, access_method,
  update_frequency, cadence, license, reliability_score, geographic_coverage, coverage, typical_lag_days, typical_lag_text,
  auth, data_fields, ingestion_method, yeto_usage, yeto_module, granularity_caveats,
  notes, tags, origin, status, active
)
FROM 'db/seeds/sources_seed_225_revised.csv'
WITH (FORMAT csv, HEADER true, NULL '', QUOTE '"', ESCAPE '"');

-- ---------------------------------------------------------------------------
-- Post-load: auto-create metadata Gap Tickets for sources missing mandatory fields
-- ---------------------------------------------------------------------------
INSERT INTO gap_ticket (gap_type, title, description, severity, status, related_source_id)
SELECT
  'REGISTRY_META' AS gap_type,
  'Missing/Incomplete registry metadata for source ' || s.src_id AS title,
  'One or more registry fields are NULL/empty/UNKNOWN: '
    || CASE WHEN s.category IS NULL OR s.category='' THEN 'category; ' ELSE '' END
    || CASE WHEN s.url IS NULL OR s.url='' THEN 'url; ' ELSE '' END
    || CASE WHEN s.access_method IS NULL OR s.access_method='' THEN 'access_method; ' ELSE '' END
    || CASE WHEN s.update_frequency IS NULL OR s.update_frequency='' THEN 'update_frequency; ' ELSE '' END
    || CASE WHEN s.cadence IS NULL THEN 'cadence; ' ELSE '' END
    || CASE WHEN s.tier='UNKNOWN' THEN 'tier(UNKNOWN); ' ELSE '' END
    || CASE WHEN s.geographic_coverage IS NULL OR s.geographic_coverage='' THEN 'geographic_coverage; ' ELSE '' END
    || 'Review the Source Registry row and resolve.' AS description,
  CASE WHEN s.tier='T1' THEN 'HIGH' ELSE 'MEDIUM' END::severity_level AS severity,
  'OPEN'::gap_ticket_status AS status,
  s.id AS related_source_id
FROM source s
WHERE (s.category IS NULL OR s.category='')
   OR (s.url IS NULL OR s.url='')
   OR (s.access_method IS NULL OR s.access_method='')
   OR (s.update_frequency IS NULL OR s.update_frequency='')
   OR (s.cadence IS NULL)
   OR (s.tier='UNKNOWN')
   OR (s.geographic_coverage IS NULL OR s.geographic_coverage='')
ON CONFLICT DO NOTHING;
