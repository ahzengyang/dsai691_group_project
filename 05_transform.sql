-- ===========================================================================
-- 05_transform.sql -- populate the normalized schema from staging.
--     psql -d flights -f 05_transform.sql
-- Safe to re-run: it truncates the target tables first.
-- ===========================================================================
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
-- airline's name, so we attach names from a small seed list. Edit freely --
-- run the "unmapped carriers" check at the bottom to see what is missing.
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
-- Union of every origin and destination, enriched with OurAirports geo data.
-- ident 'K' + IATA is the usual US mapping, but we join on iata_code directly.
WITH seen AS (
    SELECT origin_airport_id AS airport_id, origin_iata AS iata,
           origin_city AS city, origin_state AS st
    FROM staging.flights_raw
    UNION
    SELECT dest_airport_id, dest_iata, dest_city, dest_state
    FROM staging.flights_raw
),
deduped AS (
    -- an airport_id can appear with slightly different city strings over time;
    -- keep one row per id
    SELECT DISTINCT ON (airport_id)
           airport_id, iata, city, st
    FROM seen
    WHERE airport_id IS NOT NULL
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
SELECT origin_airport_id, dest_airport_id, max(distance)
FROM staging.flights_raw
WHERE origin_airport_id IS NOT NULL
  AND dest_airport_id   IS NOT NULL
  AND origin_airport_id <> dest_airport_id
GROUP BY origin_airport_id, dest_airport_id;

-- 6. flights fact -----------------------------------------------------------
-- Give every staging row a surrogate key and carry it into the fact table, so
-- step 7 can attach delay causes with a cheap integer join instead of an
-- 6-column natural-key join. The column is dropped again at the end.
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
       CASE WHEN s.cancelled = 1
            THEN nullif(upper(trim(s.cancellation_code)), '') END,
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

-- 8. indexes (created AFTER the bulk insert -- much faster that way) ---------
CREATE INDEX ix_flights_date        ON flights (flight_date);
CREATE INDEX ix_flights_airline     ON flights (airline_id, flight_date);
CREATE INDEX ix_flights_origin      ON flights (origin_airport_id, flight_date);
CREATE INDEX ix_flights_dest        ON flights (dest_airport_id, flight_date);
CREATE INDEX ix_flights_route       ON flights (route_id);
-- the workhorse index for the cascading-delay self-join:
CREATE INDEX ix_flights_tail_seq    ON flights (tail_number, flight_date, crs_dep_time)
                                     WHERE tail_number IS NOT NULL;
CREATE INDEX ix_flights_arrdelay    ON flights (arr_delay) WHERE arr_delay >= 15;

COMMIT;

VACUUM ANALYZE;

-- ---------------------------  sanity checks  -------------------------------
\echo '--- row counts ---'
SELECT 'airlines' t, count(*) FROM airlines
UNION ALL SELECT 'airports', count(*) FROM airports
UNION ALL SELECT 'aircraft', count(*) FROM aircraft
UNION ALL SELECT 'routes',   count(*) FROM routes
UNION ALL SELECT 'flights',  count(*) FROM flights
UNION ALL SELECT 'delay_causes', count(*) FROM delay_causes;

\echo '--- staging rows dropped by the routes join (should be ~0) ---'
SELECT (SELECT count(*) FROM staging.flights_raw) - (SELECT count(*) FROM flights)
       AS dropped;

\echo '--- carriers with no name in the seed list (add them above) ---'
SELECT carrier_code, airline_id FROM airlines WHERE airline_name IS NULL
ORDER BY carrier_code;

\echo '--- airports missing geo coords (OurAirports had no IATA match) ---'
SELECT count(*) FROM airports WHERE latitude IS NULL;
