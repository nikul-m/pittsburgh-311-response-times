-- 03_results.sql
-- Phase 3: SQL that supports the analysis notebook (notebooks/03_analysis.ipynb).
-- Builds on the views in 02_clean.sql (in_scope, analysis, model_data); run that file first.
-- Data: WPRDC "Pittsburgh 311 Data", downloaded 2026-11-05.


-- =====================================================================
-- R1. MAIN COUNCIL DISTRICT PER NEIGHBORHOOD
-- =====================================================================
-- Purpose: label each modeled neighborhood with a council district, so results can be
--   summarized and charted by district (the headline finding is geographic).
-- Some neighborhoods straddle district boundaries, so each gets its MAIN district:
--   the district where most of its in-scope requests were filed.
-- How it works:
--   inner query: one row per (neighborhood, district) pair with a request count;
--   ROW_NUMBER() OVER (PARTITION BY neighborhood ...): numbers the pairs within each
--     neighborhood, largest count first (PARTITION BY = group, but keep every row);
--   outer WHERE rank_in_nbhd = 1: keeps only the top district per neighborhood.
-- in_scope is used because model_data doesn't carry council_district.
-- The notebook runs this same query with pd.read_sql.
SELECT neighborhood, council_district AS main_district
FROM (
    SELECT neighborhood,
           council_district,
           COUNT(*) AS n,
           ROW_NUMBER() OVER (PARTITION BY neighborhood ORDER BY COUNT(*) DESC) AS rank_in_nbhd
    FROM in_scope
    GROUP BY neighborhood, council_district
)
WHERE rank_in_nbhd = 1
  AND neighborhood IN (SELECT DISTINCT neighborhood FROM model_data);
-- Result: 88 neighborhoods across all 9 council districts.


-- =====================================================================
-- R2. ROBUSTNESS CHECK: 14-DAY WINDOW INSTEAD OF 30
-- =====================================================================
-- Question: does the finding depend on choosing 30 days? E.g., maybe slower districts
--   only lag in the first weeks. If districts rank the same way with a 14-day window,
--   the result doesn't hinge on that choice.
-- Same rows as model_data; only the outcome changes:
--   closed_within_14d = 1 if closed within 14 days of creation, else 0.
-- No new eligibility cutoff is needed: every in-scope request is at least 30 days old.
-- The Block Group condition from `analysis` isn't needed here: the last line keeps only
--   model_data's 88 neighborhoods, which already exclude Block Groups and neighborhoods
--   under 50 requests.
-- Open the database in normal (not read-only) mode and click Write Changes afterward.
DROP VIEW IF EXISTS model_data_14d;
CREATE VIEW model_data_14d AS
SELECT neighborhood,
       subject,
       created_date_utc,
       (closed_date_utc <> '' AND julianday(closed_date_utc) - julianday(created_date_utc) <= 14) AS closed_within_14d
FROM in_scope
WHERE status NOT LIKE '%Duplicate%'
  AND status <> 'Canceled'
  AND neighborhood <> ''
  AND NOT (status LIKE '%Closed%' AND closed_date_utc = '')
  AND neighborhood IN (SELECT DISTINCT neighborhood FROM model_data);

-- Checks:
SELECT COUNT(*) AS rows_14d, COUNT(DISTINCT neighborhood) AS neighborhoods_14d
FROM model_data_14d;
-- Result: 46,875 rows, 88 neighborhoods (identical rows to model_data).

SELECT ROUND(100.0 * AVG(closed_within_14d), 1) AS pct_closed_14d
FROM model_data_14d;
-- Result: 62.0% closed within 14 days (vs. 72.7% within 30 days).
-- Model comparison (rank correlation, district medians) is in the notebook.
