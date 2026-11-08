-- 01_explore.sql
-- First look at the Pittsburgh 311 data (WPRDC "Pittsburgh 311 Data", downloaded 2026-11-05).
-- Table: requests. All columns are TEXT; empty fields are stored as '' (not NULL).
-- Every result below is on ALL rows, BEFORE any cleaning.


-- Q1: How many requests are there, and what date range do they cover?
SELECT MIN(created_date_et) AS earliest, MAX(created_date_et) AS latest, COUNT(*) AS total_count FROM requests;
-- Result: 981193 rows; earliest created_date_et = 2015-02-20T09:53:00.000; latest = 2026-11-05T12:59:31.000
-- Note: 805213 rows were created before 2025-02-04 (the new 311 system's start date).
-- Query for this
SELECT COUNT(*) AS rows_before_cutover FROM requests
WHERE created_date_et < '2025-02-04';

-- Q2: What are the 15 most common request types?
SELECT subject, COUNT(*) AS num_requests
FROM requests
GROUP BY subject
ORDER BY num_requests DESC
LIMIT 15;
-- Result: most common subject = Weeds or Debris (91261 rows).


-- Q3a: What status values exist, and how many rows have each?
SELECT status, COUNT(*) AS num_cases FROM requests
GROUP BY status
ORDER BY num_cases DESC;
-- Result: the duplicate flag has two spellings: 'Closed (Duplicate)' (4,992) and 'Closed(Duplicate)' (26).
--         Open duplicates also exist. 1 row is 'Canceled'.
-- Rule: match duplicates with LIKE '%Duplicate%', never an exact match.


-- Q3b: How many requests are not closed?
SELECT COUNT(*) AS not_closed FROM requests
WHERE status NOT LIKE '%Closed%';
-- Result: 98,142 rows = 10.0% of all rows.
-- Meaning: too large to ignore -> right-censoring matters; check whether open requests are recent or old.


-- Q3c: How many requests are flagged as duplicates?
SELECT COUNT(*) AS num_duplicates FROM requests
WHERE status  LIKE '%Duplicate%';
-- Result: 0.79% of all rows (includes open duplicates).
-- Meaning: small, so excluding them is a low-stakes cleaning decision.
