-- ===========================================================================
-- 04_load.sql -- bulk-load the cleaned CSVs into staging.
-- Run with psql from the project directory so the relative paths resolve:
--     psql -d flights -f 04_load.sql
-- \copy runs client-side, so you do NOT need superuser or server file access.
-- ===========================================================================

\echo 'Loading staging.flights_raw ...'
\copy staging.flights_raw FROM 'clean/flights.csv' WITH (FORMAT csv, HEADER true, NULL '')

\echo 'Loading staging.airports_ref ...'
\copy staging.airports_ref FROM 'clean/airports_ref.csv' WITH (FORMAT csv, HEADER true, NULL '')

ANALYZE staging.flights_raw;
ANALYZE staging.airports_ref;

SELECT 'flights_raw'  AS table_name, count(*) AS rows FROM staging.flights_raw
UNION ALL
SELECT 'airports_ref', count(*) FROM staging.airports_ref;

SELECT min(flight_date) AS first_date,
       max(flight_date) AS last_date,
       count(DISTINCT carrier_code) AS carriers
FROM staging.flights_raw;
