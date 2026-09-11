-- ===========================================================================
-- 03_schema.sql -- PostgreSQL DDL for the flight-delay database
--   staging  : wide, untyped-ish landing table matching clean/flights.csv
--   public   : normalized star schema built from staging in 05_transform.sql
-- ===========================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

-- Column order MUST match the header written by 02_prepare.py -------------
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

-- ===========================  dimensions  ==================================

DROP TABLE IF EXISTS delay_causes, flights, routes, aircraft,
                     airports, airlines, cancellation_codes CASCADE;

CREATE TABLE cancellation_codes (
    code         char(1) PRIMARY KEY,
    description  text NOT NULL
);

CREATE TABLE airlines (
    airline_id    integer PRIMARY KEY,          -- DOT_ID, stable across renames
    carrier_code  text    NOT NULL,             -- IATA-style reporting code
    airline_name  text,
    UNIQUE (carrier_code, airline_id)
);

CREATE TABLE airports (
    airport_id     integer PRIMARY KEY,         -- BTS surrogate, stable
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

-- ============================  fact table  =================================

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

    -- A cancelled flight has no arrival delay; a completed one has no code.
    CONSTRAINT ck_cancel_code CHECK (
        (cancelled AND cancellation_code IS NOT NULL) OR
        (NOT cancelled AND cancellation_code IS NULL)
    )
);

-- Only populated for arrivals delayed >= 15 min. This is a real 1:0..1
-- relationship, which is exactly why it belongs in its own table.
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
