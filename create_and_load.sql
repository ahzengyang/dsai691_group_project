-- ===========================================================================
-- create_and_load.sql -- DSAI-691 Group Project, Task 2
--
-- ONE script that: creates the database, creates every table, loads the data,
-- normalizes it, builds indexes, and runs validation queries.
--
-- USAGE (run from the project directory, with psql -- not pgAdmin):
--
--     psql -U postgres -d postgres -f create_and_load.sql
--
-- PREREQUISITES:
--   1. ./01_download.sh <SY> <SM> <EY> <EM>    populates raw/
--   2. python3 02_prepare.py                   writes clean/flights.csv
--                                              and  clean/airports_ref.csv
--
-- WHY psql AND NOT pgAdmin: this script uses \gexec, \c and \copy, which are
-- psql meta-commands. pgAdmin's query tool does not understand them.
--
-- WHY FROM THE PROJECT DIRECTORY: \copy resolves paths CLIENT-side, relative
-- to your current working directory. The paths below are deliberately
-- relative (clean/...) rather than absolute so the script runs unchanged on
-- every team member's machine.
--
-- RE-RUNNABLE: yes. Stage 1 drops and recreates every table, stage 3
-- truncates staging before loading, and stage 4 truncates the normalized
-- tables before populating them. Running this twice produces the same
-- database, not double the rows.
--
-- DATA SOURCE: Bureau of Transportation Statistics, Airline On-Time
-- Performance (Reporting Carrier). Airport geography from OurAirports.
-- Both public domain.
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

-- ===========================================================================
-- STAGE 0.  CREATE THE DATABASE
-- ---------------------------------------------------------------------------
-- CREATE DATABASE cannot run inside a transaction and cannot be run from
-- inside the database being created, so we connect to `postgres` first.
-- The \gexec trick executes the generated string only when the database is
-- absent, which keeps this script re-runnable instead of erroring out with
-- "database already exists".
-- ===========================================================================

\echo ''
\echo '=== STAGE 0: create database ==============================='

SELECT 'CREATE DATABASE flights ENCODING ''UTF8'''
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = 'flights'
)\gexec

\c flights

\echo 'Connected to:'
SELECT current_database() AS database, current_user AS connected_as;


-- ===========================================================================
-- STAGE 1.  SCHEMA
-- ---------------------------------------------------------------------------
--   staging.*  wide landing tables that mirror the cleaned CSV headers
--   public.*   the normalized model the analysis actually runs against
--
-- staging is a transient landing zone, dropped and rebuilt on every run, so
-- its tables intentionally carry no keys or constraints -- validating on the
-- way IN would reject rows we would rather inspect. All seven persistent
-- tables below have a primary key, and every relationship between them is
-- enforced by a foreign key.
-- ===========================================================================

\echo ''
\echo '=== STAGE 1: schema ========================================'

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

-- Column order MUST match the header written by 02_prepare.py --------------
CREATE TABLE staging.flights_raw (
    flight_date          date,
    carrier_code         text,
    airline_id           integer,
    flight_number        integer,
    tail_number          text,

    origin_airport_id    integer,
    origin_iata          text,
    origin_city          text,
    origin_state         text,
    dest_airport_id      integer,
    dest_iata            text,
    dest_city            text,
    dest_state           text,

    crs_dep_time         text,
    dep_time             text,
    dep_delay            numeric,
    dep_del15            smallint,
    taxi_out             numeric,
    wheels_off           text,
    wheels_on            text,
    taxi_in              numeric,
    crs_arr_time         text,
    arr_time             text,
    arr_delay            numeric,
    arr_del15            smallint,

    cancelled            smallint,
    cancellation_code    text,
    diverted             smallint,

    crs_elapsed_time     numeric,
    actual_elapsed_time  numeric,
    air_time             numeric,
    distance             numeric,

    carrier_delay        numeric,
    weather_delay        numeric,
    nas_delay            numeric,
    security_delay       numeric,
    late_aircraft_delay  numeric
);

CREATE TABLE staging.airports_ref (
    ident          text,
    type           text,
    name           text,
    latitude_deg   numeric,
    longitude_deg  numeric,
    elevation_ft   integer,
    iso_country    text,
    iso_region     text,
    municipality   text,
    iata_code      text
);

-- ---------------------------  dimensions  ----------------------------------

DROP TABLE IF EXISTS delay_causes, flights, routes, aircraft,
                     airports, airlines, cancellation_codes CASCADE;

CREATE TABLE cancellation_codes (
    code         char(1) PRIMARY KEY,
    description  text NOT NULL
);

CREATE TABLE airlines (
    airline_id    integer PRIMARY KEY,   -- DOT id: stable across mergers and
                                         -- renames, unlike the 2-letter code
    carrier_code  text    NOT NULL,
    airline_name  text,
    UNIQUE (carrier_code, airline_id)
);

CREATE TABLE airports (
    airport_id     integer PRIMARY KEY,  -- BTS surrogate id
    iata_code      text    NOT NULL,
    airport_name   text,
    city_name      text,
    state_code     char(2),
    latitude       numeric(9,6),
    longitude      numeric(9,6),
    elevation_ft   integer
);
CREATE INDEX ix_airports_iata ON airports (iata_code);

CREATE TABLE aircraft (
    tail_number   text PRIMARY KEY
);

CREATE TABLE routes (
    route_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    origin_airport_id  integer NOT NULL REFERENCES airports (airport_id),
    dest_airport_id    integer NOT NULL REFERENCES airports (airport_id),
    distance_miles     numeric,
    UNIQUE (origin_airport_id, dest_airport_id),
    CHECK (origin_airport_id <> dest_airport_id)
);

-- ----------------------------  fact table  ---------------------------------

CREATE TABLE flights (
    flight_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    flight_date          date    NOT NULL,
    airline_id           integer NOT NULL REFERENCES airlines (airline_id),
    flight_number        integer NOT NULL,
    tail_number          text             REFERENCES aircraft (tail_number),
    route_id             integer NOT NULL REFERENCES routes (route_id),
    origin_airport_id    integer NOT NULL REFERENCES airports (airport_id),
    dest_airport_id      integer NOT NULL REFERENCES airports (airport_id),

    crs_dep_time         time,
    dep_time             time,
    dep_delay            numeric,
    taxi_out             numeric,
    wheels_off           time,
    wheels_on            time,
    taxi_in              numeric,
    crs_arr_time         time,
    arr_time             time,
    arr_delay            numeric,

    cancelled            boolean NOT NULL DEFAULT false,
    cancellation_code    char(1)          REFERENCES cancellation_codes (code),
    diverted             boolean NOT NULL DEFAULT false,

    crs_elapsed_time     numeric,
    actual_elapsed_time  numeric,
    air_time             numeric,
    distance             numeric,

    -- A completed flight must not carry a cancellation reason. The converse
    -- is NOT required: BTS occasionally reports Cancelled=1 with the reason
    -- field blank, and rejecting those rows would silently lose real
    -- cancellations. The count of such rows is reported in stage 5.
    CONSTRAINT ck_cancel_code CHECK (
        cancelled OR cancellation_code IS NULL
    )
);

-- Populated only for arrivals delayed >= 15 minutes. A genuine 1:0..1
-- relationship, which is why it is a separate table rather than five more
-- mostly-null columns on `flights`.
CREATE TABLE delay_causes (
    flight_id            bigint PRIMARY KEY REFERENCES flights (flight_id)
                                ON DELETE CASCADE,
    carrier_delay        numeric NOT NULL DEFAULT 0,
    weather_delay        numeric NOT NULL DEFAULT 0,
    nas_delay            numeric NOT NULL DEFAULT 0,
    security_delay       numeric NOT NULL DEFAULT 0,
    late_aircraft_delay  numeric NOT NULL DEFAULT 0,
    CHECK (carrier_delay >= 0 AND weather_delay >= 0 AND nas_delay >= 0
           AND security_delay >= 0 AND late_aircraft_delay >= 0)
);

\echo 'Tables created:'
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('public', 'staging') AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;


-- ===========================================================================
-- STAGE 2.  LOAD THE CLEANED CSVs INTO STAGING
-- ---------------------------------------------------------------------------
-- \copy is client-side: it needs no superuser rights and no server-side file
-- access, and it reads paths relative to YOUR working directory. The TRUNCATE
-- makes a partial re-run safe -- without it, a second \copy would append and
-- silently double every row count.
-- ===========================================================================

\echo ''
\echo '=== STAGE 2: load staging =================================='

TRUNCATE staging.flights_raw, staging.airports_ref;

\echo 'Loading staging.flights_raw from clean/flights.csv ...'
\copy staging.flights_raw FROM 'clean/flights.csv' WITH (FORMAT csv, HEADER true, NULL '')

\echo 'Loading staging.airports_ref from clean/airports_ref.csv ...'
\copy staging.airports_ref FROM 'clean/airports_ref.csv' WITH (FORMAT csv, HEADER true, NULL '')

ANALYZE staging.flights_raw;
ANALYZE staging.airports_ref;

\echo 'Staging row counts:'
SELECT 'flights_raw'  AS table_name, count(*) AS rows FROM staging.flights_raw
UNION ALL
SELECT 'airports_ref', count(*) FROM staging.airports_ref;

\echo 'Date range and carrier count actually loaded:'
SELECT min(flight_date)              AS first_date,
       max(flight_date)              AS last_date,
       count(DISTINCT carrier_code)  AS carriers
FROM staging.flights_raw;


-- ===========================================================================
-- STAGE 3.  NORMALIZE
-- ---------------------------------------------------------------------------
-- Everything here runs in one transaction: either the whole normalized model
-- is built or nothing changes. TRUNCATE ... CASCADE at the top makes it
-- re-runnable.
-- ===========================================================================

\echo ''
\echo '=== STAGE 3: transform into the normalized model ==========='

BEGIN;

TRUNCATE delay_causes, flights, routes, aircraft, airports, airlines,
         cancellation_codes RESTART IDENTITY CASCADE;

-- 1. cancellation reason lookup (BTS codebook) ------------------------------
INSERT INTO cancellation_codes (code, description) VALUES
    ('A', 'Carrier'),
    ('B', 'Weather'),
    ('C', 'National Air System'),
    ('D', 'Security');

-- 2. airlines ---------------------------------------------------------------
-- The on-time extract carries the DOT id and the reporting code but NOT the
-- airline name, so names come from a seed list. Any carrier missing from the
-- list is reported by the validation block in stage 5 -- add it there.
INSERT INTO airlines (airline_id, carrier_code, airline_name)
SELECT s.airline_id,
       s.carrier_code,
       n.airline_name
FROM (
    SELECT DISTINCT airline_id, carrier_code
    FROM staging.flights_raw
    WHERE airline_id IS NOT NULL
) s
LEFT JOIN (VALUES
    ('AA','American Airlines'),      ('AS','Alaska Airlines'),
    ('B6','JetBlue Airways'),        ('DL','Delta Air Lines'),
    ('F9','Frontier Airlines'),      ('G4','Allegiant Air'),
    ('HA','Hawaiian Airlines'),      ('NK','Spirit Airlines'),
    ('UA','United Airlines'),        ('WN','Southwest Airlines'),
    ('9E','Endeavor Air'),           ('MQ','Envoy Air'),
    ('OH','PSA Airlines'),           ('OO','SkyWest Airlines'),
    ('YV','Mesa Airlines'),          ('YX','Republic Airways'),
    ('QX','Horizon Air'),            ('ZW','Air Wisconsin'),
    ('C5','CommuteAir'),             ('EM','Empire Airlines'),
    ('PT','Piedmont Airlines'),      ('VX','Virgin America')
) AS n(code, airline_name) ON n.code = s.carrier_code;

-- 3. airports ---------------------------------------------------------------
-- Union of every origin and destination, enriched with OurAirports geography.
WITH seen AS (
    SELECT origin_airport_id AS airport_id, origin_iata AS iata,
           origin_city AS city, origin_state AS st
    FROM staging.flights_raw
    UNION
    SELECT dest_airport_id, dest_iata, dest_city, dest_state
    FROM staging.flights_raw
),
deduped AS (
    -- one airport_id can appear with slightly different city strings;
    -- keep exactly one row per id
    SELECT DISTINCT ON (airport_id)
           airport_id, iata, city, st
    FROM seen
    WHERE airport_id IS NOT NULL
      AND coalesce(iata, '') <> ''
    ORDER BY airport_id, city
)
INSERT INTO airports (airport_id, iata_code, airport_name, city_name,
                      state_code, latitude, longitude, elevation_ft)
SELECT d.airport_id,
       d.iata,
       r.name,
       d.city,
       nullif(d.st, ''),
       r.latitude_deg,
       r.longitude_deg,
       r.elevation_ft
FROM deduped d
LEFT JOIN LATERAL (
    SELECT * FROM staging.airports_ref a
    WHERE a.iata_code = d.iata
    ORDER BY (a.type = 'large_airport') DESC, a.ident
    LIMIT 1
) r ON true;

-- 4. aircraft ---------------------------------------------------------------
INSERT INTO aircraft (tail_number)
SELECT DISTINCT tail_number
FROM staging.flights_raw
WHERE tail_number IS NOT NULL AND tail_number <> '';

-- 5. routes -----------------------------------------------------------------
INSERT INTO routes (origin_airport_id, dest_airport_id, distance_miles)
SELECT s.origin_airport_id, s.dest_airport_id, max(s.distance)
FROM staging.flights_raw s
JOIN airports o ON o.airport_id = s.origin_airport_id
JOIN airports d ON d.airport_id = s.dest_airport_id
WHERE s.origin_airport_id <> s.dest_airport_id
GROUP BY s.origin_airport_id, s.dest_airport_id;

-- 6. flights fact -----------------------------------------------------------
-- Each staging row gets a surrogate key that is carried into the fact table,
-- so stage 7 can attach delay causes with a cheap integer join instead of a
-- six-column natural-key join. The column is dropped again afterwards.
ALTER TABLE staging.flights_raw ADD COLUMN IF NOT EXISTS stg_id bigserial;
ALTER TABLE flights            ADD COLUMN IF NOT EXISTS src_id bigint;

-- hhmm text -> time. '2400' was already folded to '0000' by 02_prepare.py.
CREATE OR REPLACE FUNCTION hhmm_to_time(t text) RETURNS time AS $$
    SELECT CASE
        WHEN t IS NULL OR t = '' THEN NULL
        ELSE make_time((left(t,2))::int, (right(t,2))::int, 0)
    END;
$$ LANGUAGE sql IMMUTABLE;

INSERT INTO flights (
    flight_date, airline_id, flight_number, tail_number, route_id,
    origin_airport_id, dest_airport_id,
    crs_dep_time, dep_time, dep_delay, taxi_out, wheels_off, wheels_on,
    taxi_in, crs_arr_time, arr_time, arr_delay,
    cancelled, cancellation_code, diverted,
    crs_elapsed_time, actual_elapsed_time, air_time, distance, src_id
)
SELECT s.flight_date,
       s.airline_id,
       s.flight_number,
       nullif(s.tail_number, ''),
       r.route_id,
       s.origin_airport_id,
       s.dest_airport_id,
       hhmm_to_time(s.crs_dep_time),
       hhmm_to_time(s.dep_time),
       s.dep_delay,
       s.taxi_out,
       hhmm_to_time(s.wheels_off),
       hhmm_to_time(s.wheels_on),
       s.taxi_in,
       hhmm_to_time(s.crs_arr_time),
       hhmm_to_time(s.arr_time),
       s.arr_delay,
       (s.cancelled = 1),
       -- only a genuine A/B/C/D survives; anything else becomes NULL so the
       -- foreign key to cancellation_codes cannot fail mid-load
       CASE WHEN s.cancelled = 1
            THEN nullif(upper(trim(s.cancellation_code)), '')
            END,
       (s.diverted = 1),
       s.crs_elapsed_time,
       s.actual_elapsed_time,
       s.air_time,
       s.distance,
       s.stg_id
FROM staging.flights_raw s
JOIN routes r
  ON r.origin_airport_id = s.origin_airport_id
 AND r.dest_airport_id   = s.dest_airport_id;

-- 7. delay causes -----------------------------------------------------------
INSERT INTO delay_causes (flight_id, carrier_delay, weather_delay,
                          nas_delay, security_delay, late_aircraft_delay)
SELECT f.flight_id,
       coalesce(s.carrier_delay, 0),
       coalesce(s.weather_delay, 0),
       coalesce(s.nas_delay, 0),
       coalesce(s.security_delay, 0),
       coalesce(s.late_aircraft_delay, 0)
FROM flights f
JOIN staging.flights_raw s ON s.stg_id = f.src_id
WHERE coalesce(s.carrier_delay,0) + coalesce(s.weather_delay,0)
    + coalesce(s.nas_delay,0)     + coalesce(s.security_delay,0)
    + coalesce(s.late_aircraft_delay,0) > 0;

ALTER TABLE flights DROP COLUMN src_id;

-- 8. indexes ----------------------------------------------------------------
-- Built AFTER the bulk insert: maintaining them during a multi-hundred-
-- thousand-row insert is substantially slower than building them once.
CREATE INDEX ix_flights_date     ON flights (flight_date);
CREATE INDEX ix_flights_airline  ON flights (airline_id, flight_date);
CREATE INDEX ix_flights_origin   ON flights (origin_airport_id, flight_date);
CREATE INDEX ix_flights_dest     ON flights (dest_airport_id, flight_date);
CREATE INDEX ix_flights_route    ON flights (route_id);
-- the workhorse for the cascading-delay self-join in 06_queries.sql:
CREATE INDEX ix_flights_tail_seq ON flights (tail_number, flight_date,
                                             crs_dep_time)
                                  WHERE tail_number IS NOT NULL;
CREATE INDEX ix_flights_arrdelay ON flights (arr_delay) WHERE arr_delay >= 15;

COMMIT;

VACUUM ANALYZE;


-- ===========================================================================
-- STAGE 4.  VALIDATION -- did the load do what we think it did?
-- ===========================================================================

\echo ''
\echo '=== STAGE 4: validation ===================================='

\echo '--- row counts per table (all seven should be non-zero) ---'
SELECT 'airlines'     AS table_name, count(*) FROM airlines
UNION ALL SELECT 'airports',           count(*) FROM airports
UNION ALL SELECT 'aircraft',           count(*) FROM aircraft
UNION ALL SELECT 'routes',             count(*) FROM routes
UNION ALL SELECT 'flights',            count(*) FROM flights
UNION ALL SELECT 'delay_causes',       count(*) FROM delay_causes
UNION ALL SELECT 'cancellation_codes', count(*) FROM cancellation_codes
ORDER BY 1;

\echo '--- staging rows not carried into flights (expect ~0) ---'
SELECT (SELECT count(*) FROM staging.flights_raw)
     - (SELECT count(*) FROM flights) AS rows_dropped_by_routes_join;

\echo '--- carriers with no name in the seed list (add them in stage 3.2) ---'
SELECT carrier_code, airline_id
FROM airlines
WHERE airline_name IS NULL
ORDER BY carrier_code;

\echo '--- airports with no OurAirports geo match ---'
SELECT count(*) AS airports_missing_coordinates
FROM airports WHERE latitude IS NULL;

\echo '--- cancellations BTS reported without a reason code ---'
SELECT count(*) AS cancelled_without_code
FROM flights WHERE cancelled AND cancellation_code IS NULL;

\echo '--- keys and constraints actually in place ---'
SELECT tc.table_name,
       tc.constraint_type,
       count(*) AS n
FROM information_schema.table_constraints tc
WHERE tc.table_schema = 'public'
  AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE', 'CHECK')
GROUP BY tc.table_name, tc.constraint_type
ORDER BY tc.table_name, tc.constraint_type;


-- ===========================================================================
-- STAGE 5.  EXPLORATORY QUERIES
-- ---------------------------------------------------------------------------
-- Small, fast checks that show the data is real and that we understand its
-- shape. The full analysis lives in 06_queries.sql.
-- ===========================================================================

\echo ''
\echo '=== STAGE 5: exploration ==================================='

\echo '--- E1. what period and how much volume do we actually have? ---'
SELECT min(flight_date)                    AS first_date,
       max(flight_date)                    AS last_date,
       count(*)                            AS total_flights,
       count(DISTINCT flight_date)         AS days_covered,
       round(count(*)::numeric
             / count(DISTINCT flight_date)) AS avg_flights_per_day
FROM flights;

\echo '--- E2. top 10 carriers by volume, with headline delay stats ---'
SELECT a.carrier_code,
       coalesce(a.airline_name, '(unmapped)')          AS airline,
       count(*)                                        AS flights,
       round(avg(f.arr_delay), 1)                      AS avg_arr_delay_min,
       round(100.0 * avg(f.cancelled::int), 2)         AS cancel_pct
FROM flights f
JOIN airlines a USING (airline_id)
GROUP BY a.carrier_code, a.airline_name
ORDER BY flights DESC
LIMIT 10;

\echo '--- E3. spot-check: five real rows, fully joined ---'
SELECT f.flight_date,
       a.carrier_code,
       f.flight_number,
       f.tail_number,
       o.iata_code  AS origin,
       de.iata_code AS dest,
       f.crs_dep_time,
       f.dep_delay,
       f.arr_delay
FROM flights f
JOIN airlines a  USING (airline_id)
JOIN airports o  ON o.airport_id  = f.origin_airport_id
JOIN airports de ON de.airport_id = f.dest_airport_id
WHERE NOT f.cancelled
ORDER BY f.flight_id
LIMIT 5;

\echo '--- E4. does the 1:0..1 delay_causes split hold up? ---'
SELECT count(*) FILTER (WHERE f.arr_delay >= 15)          AS arrivals_late_15,
       count(*) FILTER (WHERE d.flight_id IS NOT NULL)    AS rows_in_delay_causes,
       count(*) FILTER (WHERE d.flight_id IS NOT NULL
                          AND f.arr_delay < 15)           AS causes_without_late_arrival
FROM flights f
LEFT JOIN delay_causes d USING (flight_id);

\echo '--- E5. delay minutes by cause, whole dataset ---'
SELECT round(sum(carrier_delay))       AS carrier_min,
       round(sum(weather_delay))       AS weather_min,
       round(sum(nas_delay))           AS nas_min,
       round(sum(security_delay))      AS security_min,
       round(sum(late_aircraft_delay)) AS late_aircraft_min
FROM delay_causes;

\echo '--- E6. busiest 10 origin airports ---'
SELECT ap.iata_code,
       ap.city_name,
       ap.state_code,
       count(*)                   AS departures,
       round(avg(f.dep_delay), 1) AS avg_dep_delay_min
FROM flights f
JOIN airports ap ON ap.airport_id = f.origin_airport_id
WHERE NOT f.cancelled
GROUP BY ap.iata_code, ap.city_name, ap.state_code
ORDER BY departures DESC
LIMIT 10;

\echo '--- E7. cancellations by reason ---'
SELECT c.code,
       c.description,
       count(*) AS cancellations
FROM flights f
JOIN cancellation_codes c ON c.code = f.cancellation_code
WHERE f.cancelled
GROUP BY c.code, c.description
ORDER BY cancellations DESC;

\echo ''
\echo '=== DONE ==================================================='
\echo 'Database `flights` is built and populated.'
\echo 'Connect Metabase with:'
\echo '    host     host.docker.internal   (Postgres running natively on Mac)'
\echo '    port     5432'
\echo '    database flights'
\echo ''
