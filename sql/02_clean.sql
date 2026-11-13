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
-- Use created_date_utc / closed_date_utc: ET times shift an hour at daylight-saving changes.
-- Response time in hours: (julianday(closed_date_utc) - julianday(created_date_utc)) * 24

-- D1: Any requests closed BEFORE they were created? Any open > 1 year?
-- TODO

-- Result:
-- DECISION:


-- =====================================================================
-- E. SIMPLE EXCLUSIONS: duplicates, Canceled, blank neighborhood/subject
-- =====================================================================

-- E1: How many new-era rows have a blank neighborhood or blank subject?
-- TODO

-- Result:
-- DECISION: exclude duplicates (LIKE '%Duplicate%'), the Canceled status, and ____


-- =====================================================================
-- F. SAMPLE SIZE: requests per neighborhood after cleaning
-- =====================================================================

-- F1: Count of cleaned requests per neighborhood, smallest first
-- TODO

-- Result:
-- DECISION: minimum requests per neighborhood = ____


-- =====================================================================
-- G. FINAL ANALYSIS TABLE
-- =====================================================================
-- Build a VIEW that applies every DECISION above and outputs one row per request with:
-- neighborhood, subject, created time, response time in hours (UTC).
-- Note: open the database in normal (not read-only) mode in DB Browser to create a view,
-- and click Write Changes afterward.
-- TODO: CREATE VIEW analysis AS ...

-- Rows remaining after each step (for the README's cleaning funnel):
-- Start: 981,193 -> after date range: ____ -> after duplicates/Canceled/blanks: ____
--   -> after referrals: ____ -> after censoring cutoff: ____ -> after impossible values: ____
