-- 02_clean.sql
-- Phase 2: explore data-quality issues and build the cleaned analysis table.
-- Data: WPRDC "Pittsburgh 311 Data", downloaded 2026-11-05. Table: requests (all TEXT; empty = '').
-- System cutover: 2025-02-04 (new 311 system). "Old era" = created before it; "new era" = on or after.
-- Results are BEFORE cleaning unless a comment says otherwise.


-- =====================================================================
-- A. DATE RANGE: is old-era data comparable to new-era data?
-- =====================================================================

-- A1: What share of NEW-era requests are not closed?
SELECT status, COUNT(*) FROM requests
WHERE created_date_et >= '2025-02-04'
GROUP BY status;

-- Result: 18.7% not closed (32,961 of 175,980), vs. 10% across all rows.
-- Meaning: the old (mostly closed) records were diluting the open share.


-- A2: How many of the 98,142 open requests are from the OLD era?
SELECT status, COUNT(*) FROM requests
WHERE created_date_et <'2025-02-04'
GROUP BY status;

-- Result: 65,181 (two-thirds of all open requests).
-- Meaning: years-old "open" tickets are almost certainly stale, never-closed records.


-- A3: How many duplicates were flagged in each era?
SELECT status, COUNT(*) FROM requests
WHERE created_date_et >= '2025-02-04'
GROUP BY status;
SELECT status, COUNT(*) FROM requests
WHERE created_date_et <'2025-02-04'
GROUP BY status;

-- Result: all but 5 duplicates are new-era.
-- Meaning: the old system essentially never flagged duplicates -> undetectable duplicates in old data.


-- A4: What share of closed requests closed instantly, by era?
-- Old era (exact second = same minute here, since old timestamps have no seconds):
SELECT SUM(created_date_et = closed_date_et) AS zero_sec_request,
       COUNT(*) AS total_closed,
       100.0 * SUM(created_date_et = closed_date_et) / COUNT(*) AS pct_zero_sec
FROM requests
WHERE created_date_et < '2025-02-04' AND status LIKE '%Closed%';
-- Result: 2.06%

-- New era, same-minute comparison (fair vs. the old system's minute-level clock):
SELECT SUM(substr(created_date_et, 1, 16) = substr(closed_date_et, 1, 16)) AS same_min_request,
       COUNT(*) AS total_closed,
       100.0 * SUM(substr(created_date_et, 1, 16) = substr(closed_date_et, 1, 16)) / COUNT(*) AS pct_same_min
FROM requests
WHERE created_date_et >= '2025-02-04' AND status LIKE '%Closed%';

-- Result: .352%  (exact-second version was 0.208%)
-- Note: old system recorded time only to the minute (seconds always :00).

-- DECISION: YES (keep only requests created on or after '2025-02-04'?)


-- =====================================================================
-- B. REFERRALS: which instant closures are handoffs, not fixes?
-- =====================================================================

-- B1: Which case_owner values have the highest share of instant closures?
SELECT case_owner,
       SUM(substr(created_date_et, 1, 16) = substr(closed_date_et, 1, 16)) AS instant,
       COUNT(*) AS closed,
       ROUND(100.0 * SUM(substr(created_date_et, 1, 16) = substr(closed_date_et, 1, 16)) / COUNT(*), 2) AS pct_instant
FROM requests 
WHERE created_date_et >= '2025-02-04' AND status LIKE '%Closed%'
GROUP BY case_owner
HAVING COUNT(*)  >= 50
ORDER BY pct_instant DESC;
-- Result: I checked for the documented referral pattern and it doesn’t exist in the new system
-- (top rate is 7.2%(this is a completely blank owner), departments under 1%)

-- B2: Blank Case Owner Investigations
SELECT subject,
       COUNT(*) AS num_requests, SUM(status LIKE '%Closed%') AS num_closed
FROM requests 
WHERE created_date_et >= '2025-02-04' AND status LIKE '%Closed%' AND case_owner = ''
GROUP BY subject
ORDER BY COUNT(*) DESC;

-- What we see is that these are normal requests such as potholes, recycling violations, etc.
-- They just have no case owner

-- DECISION: (1) No referral exclusion by owner: 
-- no department shows the referral pattern (all under 1% instant). 
-- (2) Exclude rows where case_owner = '' (no responsible department; 
-- instant rate 7x higher than assigned requests).


-- =====================================================================
-- C. CENSORING: open requests and the 90-day cutoff
-- =====================================================================
-- Cutoff: 90 days before the download date (2026-11-05) = '2026-08-07'.
-- Requests created after that haven't had a fair chance to close.

-- C1: Are new-era open requests recent or months old? (e.g., count open requests by created month)
SELECT substr(created_date_et, 1, 7) AS created_month,
       COUNT(*) AS total,
       SUM(status NOT LIKE '%Closed%') AS still_open,
       ROUND(100.0 * SUM(status NOT LIKE '%Closed%') / COUNT(*), 1) AS pct_open
FROM requests
WHERE created_date_et >= '2025-02-04' AND case_owner != ''
GROUP BY created_month
ORDER BY created_month;
-- Result: Open share never falls below ~11%; 
-- ~15% of requests over a year old are still open. 
-- 90-day cutoff alone does not fix censoring.

-- C1b: Which subjects have the most never-closed requests? (new era, 90+ days old, no blank owner)
SELECT subject, COUNT(*) AS total,
       SUM(status NOT LIKE '%Closed%') AS still_open,
       ROUND(100.0 * SUM(status NOT LIKE '%Closed%') / COUNT(*), 1) AS pct_open
FROM requests
WHERE created_date_et >= '2025-02-04' AND created_date_et < '2026-08-07' AND case_owner != ''
GROUP BY subject
HAVING COUNT(*) >= 100
ORDER BY pct_open DESC;

-- Result: never-closed requests are concentrated in planning/feedback, enforcement, police and
--         outside-agency subjects (93-100% open: Traffic Calming, Crashes and Close Calls, Paving
--         Request, Bicycle Safety...). Core services (potholes, pickups, streetlights) not in top 30.
-- Meaning: for those subjects "closed" isn't the expected outcome -> restrict scope to physical services,
--          chosen by what the request IS, not by its open share (that would be circular).


-- C1c: Open share for the highest-volume subjects
SELECT subject, COUNT(*) AS total,
       SUM(status NOT LIKE '%Closed%') AS still_open,
       ROUND(100.0 * SUM(status NOT LIKE '%Closed%') / COUNT(*), 1) AS pct_open
FROM requests
WHERE created_date_et >= '2025-02-04' AND created_date_et < '2026-08-07' AND case_owner != ''
GROUP BY subject
HAVING COUNT(*) >= 100
ORDER BY total DESC
LIMIT 25;

-- Result:
-- DECISION (scope): keep 8 physical city-crew services with >= ~1,500 requests: Missed Pick Up, Potholes,
--   Street Light Concerns, Litter on Public Property, Repair or Replace a Sign, Street Cleaning/Sweeping,
--   City Tree Maintenance, Overgrowth.
-- DECISION (outcome): closed within 30 days, so still-open requests count instead of being dropped.

-- C1d: Who handles the unclear subjects? (new era, 90+ days old, no blank owner)
-- Purpose: decide scope by what the service IS (who does the work), not by its open share.
SELECT subject,
       case_owner,
       COUNT(*) AS num_requests
FROM requests
WHERE created_date_et >= '2025-02-04'
  AND created_date_et < '2026-08-07'
  AND case_owner <> ''
  AND subject IN ('Refuse or Recycling Violations', 'Weeds or Debris', 'Overgrowth', 'Snow/Ice Removal')
GROUP BY subject, case_owner
ORDER BY subject, num_requests DESC;

-- Result:
--   Refuse or Recycling Violations -> main owner: DPW – Street Maintenance
--   Weeds or Debris                -> main owner: PLI - Permits, Licenses, and Inspections
--   Overgrowth                     -> main owner: DPW ES Enforcement
--   Snow/Ice Removal               -> bulk-closed (0.0% open, Jan 2026 storm spike)
-- Rule: city crew department (e.g., DPW) = service -> keep; inspection/permits/enforcement = exclude.
-- Result: Overgrowth -> DPW Street Maintenance (crews, keep); Weeds or Debris -> PLI (inspections of
--   private property, exclude); Refuse or Recycling Violations -> DPW ES Enforcement (exclude);
--   Snow/Ice Removal -> DPW crews but bulk-closed after the Jan 2026 storm (exclude).

-- C2: cut. Superseded by the outcome decision (closed within 30 days); per-neighborhood rates are in section F and Phase 3.


-- =====================================================================
-- D. RESPONSE TIME: compute in UTC and check for impossible values
-- =====================================================================
--Use this to clear current view
DROP VIEW IF EXISTS in_scope;
--View base being used from now on 
CREATE VIEW in_scope AS
SELECT *
FROM requests
WHERE created_date_et >= '2025-02-04'              -- A: new system only
  AND created_date_et < '2026-10-06'               -- C: 30-day eligibility cutoff (download 2026-11-05)
  AND case_owner <> ''                             -- B: owner assigned
  AND subject IN ('Missed Pick Up', 'Potholes', 'Street Light Concerns', 'Litter on Public Property',
                  'Repair or Replace a Sign', 'Street Cleaning/Sweeping', 'City Tree Maintenance',
                  'Overgrowth');                   -- C: 8 physical city-crew services

SELECT COUNT(*) AS in_scope_rows FROM in_scope;
-- Result: 49,440 rows (funnel: 981,193 -> 49,440)

-- Response time uses UTC columns: ET times shift an hour at daylight-saving changes.
-- Response time in hours: (julianday(closed_date_utc) - julianday(created_date_utc)) * 24

-- D1: Any requests closed BEFORE they were created? (data errors)
SELECT COUNT(*) AS closed_before_created
FROM in_scope
WHERE closed_date_utc <> ''
  AND julianday(closed_date_utc) < julianday(created_date_utc);
-- Result: There are no requests closed before they were created


-- D2: Status says closed, but there's no closed date? (can't compute a time)
SELECT COUNT(*) AS closed_no_date
FROM in_scope
WHERE status LIKE '%Closed%'
  AND closed_date_utc = '';
-- Result: There are 7 requests that say they are closed but have no closed date


-- D3: Status says NOT closed, but there IS a closed date? (reopened requests?)
SELECT status, COUNT(*) AS open_with_date
FROM in_scope
WHERE status NOT LIKE '%Closed%'
  AND closed_date_utc <> ''
GROUP BY status
ORDER BY open_with_date DESC;
-- Result: 0 rows (no open requests have a closed date)


-- D4: Closed after more than a year? (possible, but worth knowing how many)
SELECT COUNT(*) AS over_one_year
FROM in_scope
WHERE closed_date_utc <> ''
  AND julianday(closed_date_utc) - julianday(created_date_utc) > 365;
-- Result: 100 requests are closed after more than a year

-- DECISION (outcome definition): closed_within_30d = 1 if closed_date_utc <> '' AND
--   response time <= 30 hours; otherwise 0 (open requests and late closures count as 0).
-- DECISION (exclusions): drop the 7 rows marked Closed with no closed date (D2).
--   Keep the 100 closed after >1 year (D4): real slow cases, coded 0.


-- =====================================================================
-- E. SIMPLE EXCLUSIONS: duplicates, Canceled, blank neighborhood
-- =====================================================================
-- (Blank subject is impossible here: in_scope only keeps the 8 named subjects.)

-- E1: How many in-scope rows are duplicates?
SELECT COUNT(*) AS num_duplicates
FROM in_scope
WHERE status LIKE '%Duplicate%';
-- Result: 1,516 (3.1%). Higher than 0.79% overall: physical problems get reported by several neighbors.

-- E2: How many are Canceled?
SELECT COUNT(*) AS num_canceled
FROM in_scope
WHERE status = 'Canceled';
-- Result: 0 (the one Canceled row was outside the 8 services).

-- E3: How many have a blank neighborhood?
SELECT COUNT(*) AS blank_neighborhood
FROM in_scope
WHERE neighborhood = '';
-- Result: 506 (1.0%). Can't be assigned to a neighborhood.

-- E4: How many in-scope requests closed within 30 days? (before exclusions)
SELECT COUNT(*) AS closed_in_30
FROM in_scope
WHERE closed_date_utc <> ''
  AND julianday(closed_date_utc) - julianday(created_date_utc) <= 30;
-- Result: 35,488 of 49,440 = 71.8%.

-- E5: Final row count with ALL exclusions applied at once
SELECT COUNT(*) AS final_rows
FROM in_scope
WHERE status NOT LIKE '%Duplicate%'
  AND status <> 'Canceled'
  AND neighborhood <> ''
  AND NOT (status LIKE '%Closed%' AND closed_date_utc = '');   -- D2 rows
-- Result: 47,458. Subtracting exclusion counts gives 47,411; the 47-row gap is rows in
--   two exclusion groups at once (e.g., a duplicate with a blank neighborhood), which
--   subtraction removes twice. Always compute the final count in one query.

-- DECISION: exclude duplicates (status LIKE '%Duplicate%'), Canceled, blank neighborhood,
--   and the 7 D2 rows (marked Closed with no closed date).


-- =====================================================================
-- G. FINAL ANALYSIS VIEW   (build this BEFORE section F)
-- =====================================================================
-- analysis = in_scope + every exclusion from D and E, with only the columns the model needs:
--   neighborhood, subject, created_date_utc, and closed_within_30d (1 = closed within 30 days, else 0).
-- Open the database in normal (not read-only) mode and click Write Changes afterward.

DROP VIEW IF EXISTS analysis;
CREATE VIEW analysis AS
SELECT neighborhood,
       subject,
       created_date_utc,
       (closed_date_utc <> '' AND julianday(closed_date_utc) - julianday(created_date_utc) <= 30) AS closed_within_30d
FROM in_scope
WHERE status NOT LIKE '%Duplicate%'
  AND status <> 'Canceled'
  AND neighborhood <> ''
  AND NOT (status LIKE '%Closed%' AND closed_date_utc = '');

-- Check: SELECT COUNT(*) FROM analysis;   -- should be 47,458
-- Result: 
SELECT COUNT(*) FROM analysis; -- 47,458
SELECT closed_within_30d, COUNT(*) FROM analysis GROUP BY closed_within_30d; --0	12963, 1	34495
SELECT AVG(closed_within_30d) FROM analysis; --0.73


-- =====================================================================
-- F. SAMPLE SIZE: requests per neighborhood   (run AFTER the analysis view exists)
-- =====================================================================

-- F1: How many distinct neighborhoods are there? (Pittsburgh officially has 90)
SELECT COUNT(DISTINCT neighborhood)
FROM analysis;
-- Result: 95

-- F2: Requests per neighborhood, with the raw (unadjusted) 30-day closure rate, smallest first
SELECT neighborhood, ROUND(AVG(closed_within_30d)*100,1), COUNT(*) AS num_requests
FROM analysis
GROUP BY neighborhood
ORDER BY COUNT(*);

-- Result:
--Arlington Heights	78.6	14
--Block Group 4	57.8	45
--St. Clair	77.6	49
--Glen Hazel	74.1	54
--Northview Heights	81.5	54
--Esplen	80.0	60
--Ridgemont	91.9	62
--East Carnegie	82.7	75
--South Shore	57.1	77
--Mt. Oliver	75.6	90
--Bedford Dwellings	68.8	96
--Oakwood	78.3	106
--Chateau	67.0	112
--North Shore	65.2	112

-- Note: raw rates are confounded by request mix (e.g., tree-heavy neighborhoods look slow);
--   the Phase 3 regression separates neighborhood from request type. 
-- BLOCK GROUPS aren't neighborhoods, and are census use only, so we will ignore them. There are 5 block groups, which explains why there are 95 distinct neighborhoods in F1.
-- DECISION: minimum requests per neighborhood = 50, I chose 50 rather than 100 because a stricter cutoff would drop several small, lower-income neighborhoods that matter most for the question


--rewritten analysis scope to exclude the block groups
DROP VIEW IF EXISTS analysis;
CREATE VIEW analysis AS
SELECT neighborhood,
       subject,
       created_date_utc,
       (closed_date_utc <> '' AND julianday(closed_date_utc) - julianday(created_date_utc) <= 30) AS closed_within_30d
FROM in_scope
WHERE status NOT LIKE '%Duplicate%'
  AND status <> 'Canceled'
  AND neighborhood <> ''
  AND NOT (status LIKE '%Closed%' AND closed_date_utc = '')
  AND neighborhood NOT LIKE '%Block Group%';

--new 'model data' view to exclude neighborhoods under 50 requests
DROP VIEW IF EXISTS model_data;
CREATE VIEW model_data AS
SELECT *
FROM analysis
WHERE neighborhood IN (
    SELECT neighborhood
    FROM analysis
    GROUP BY neighborhood
    HAVING COUNT(*) >= 50
);

-- Result: 46,875 rows, 88 neighborhoods, 72.7% closed within 30 days.

-- =====================================================================
-- CLEANING FUNNEL (for the README) - fill with CUMULATIVE counts in Phase 4
-- =====================================================================
-- All rows:                                              981,193
-- + new system only (created >= 2025-02-04):             175,980
-- + 30-day eligibility cutoff (created < 2026-10-06):    ____
-- + owner assigned (case_owner <> ''):                   ____
-- + 8 physical city-crew services:                        49,440
-- + exclusions (duplicates, Canceled, blank
--   neighborhood, closed-without-date):                   47,458
-- + minimum-sample rule (section F):                     ____
