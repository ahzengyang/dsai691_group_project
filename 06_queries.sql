-- ===========================================================================
-- 06_queries.sql -- the "story" queries. Each block is standalone.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Q1. On-time rankings by carrier
--     "On time" = arrived less than 15 minutes late (the DOT definition).
--     Cancelled and diverted flights are excluded from the rate but counted
--     separately, because an airline that cancels its worst flights would
--     otherwise look punctual.
-- ---------------------------------------------------------------------------
SELECT a.carrier_code,
       coalesce(a.airline_name, '(unmapped)')            AS airline,
       count(*)                                          AS scheduled,
       round(100.0 * avg((f.arr_delay < 15)::int)
             FILTER (WHERE NOT f.cancelled AND NOT f.diverted), 1) AS on_time_pct,
       round(100.0 * avg(f.cancelled::int), 2)           AS cancel_pct,
       round(avg(f.arr_delay) FILTER (WHERE f.arr_delay > 0), 1)   AS avg_delay_when_late,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY f.arr_delay)    AS p90_arr_delay
FROM flights f
JOIN airlines a USING (airline_id)
GROUP BY a.carrier_code, a.airline_name
HAVING count(*) > 10000
ORDER BY on_time_pct DESC;


-- ---------------------------------------------------------------------------
-- Q2. Worst airports for departures (min 20k departures)
-- ---------------------------------------------------------------------------
SELECT ap.iata_code,
       ap.city_name,
       count(*)                                    AS departures,
       round(avg(f.dep_delay), 1)                  AS avg_dep_delay,
       round(100.0 * avg((f.dep_delay >= 15)::int), 1) AS pct_delayed_15,
       round(avg(f.taxi_out), 1)                   AS avg_taxi_out
FROM flights f
JOIN airports ap ON ap.airport_id = f.origin_airport_id
WHERE NOT f.cancelled
GROUP BY ap.iata_code, ap.city_name
HAVING count(*) >= 20000
ORDER BY avg_dep_delay DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- Q3. Weather vs carrier vs everything else -- share of total delay minutes
-- ---------------------------------------------------------------------------
SELECT a.carrier_code,
       coalesce(a.airline_name, '(unmapped)') AS airline,
       round(100.0 * sum(d.carrier_delay)       / nullif(sum(tot.m),0), 1) AS pct_carrier,
       round(100.0 * sum(d.weather_delay)       / nullif(sum(tot.m),0), 1) AS pct_weather,
       round(100.0 * sum(d.nas_delay)           / nullif(sum(tot.m),0), 1) AS pct_nas,
       round(100.0 * sum(d.security_delay)      / nullif(sum(tot.m),0), 1) AS pct_security,
       round(100.0 * sum(d.late_aircraft_delay) / nullif(sum(tot.m),0), 1) AS pct_late_aircraft,
       sum(tot.m)::bigint AS total_delay_minutes
FROM delay_causes d
JOIN flights  f USING (flight_id)
JOIN airlines a USING (airline_id)
CROSS JOIN LATERAL (
    SELECT d.carrier_delay + d.weather_delay + d.nas_delay
         + d.security_delay + d.late_aircraft_delay AS m
) tot
GROUP BY a.carrier_code, a.airline_name
ORDER BY total_delay_minutes DESC;


-- ---------------------------------------------------------------------------
-- Q4. CASCADING DELAYS -- the centrepiece query.
--     Chain flights by tail number within a day, then ask: how well does the
--     delay of leg N predict the delay of leg N+1 for the same airframe?
--     Note the ground-time term: a long scheduled turnaround absorbs delay.
-- ---------------------------------------------------------------------------
WITH legs AS (
    SELECT f.tail_number,
           f.flight_date,
           f.arr_delay,
           f.crs_arr_time,
           f.dest_airport_id,
           lead(f.dep_delay)         OVER w AS next_dep_delay,
           lead(f.crs_dep_time)      OVER w AS next_crs_dep,
           lead(f.origin_airport_id) OVER w AS next_origin
    FROM flights f
    WHERE f.tail_number IS NOT NULL
      AND NOT f.cancelled AND NOT f.diverted
    WINDOW w AS (PARTITION BY f.tail_number, f.flight_date
                 ORDER BY f.crs_dep_time)
),
chained AS (
    SELECT arr_delay,
           next_dep_delay,
           EXTRACT(epoch FROM (next_crs_dep - crs_arr_time)) / 60 AS ground_minutes
    FROM legs
    WHERE next_dep_delay IS NOT NULL
      AND next_origin = dest_airport_id   -- genuine continuation, not a gap
      AND next_crs_dep > crs_arr_time     -- drop rows that wrap past midnight
)
SELECT width_bucket(arr_delay, 0, 180, 6)             AS inbound_delay_bucket,
       count(*)                                       AS legs,
       round(avg(arr_delay), 1)                       AS avg_inbound_arr_delay,
       round(avg(next_dep_delay), 1)                  AS avg_next_dep_delay,
       round(avg(ground_minutes), 1)                  AS avg_sched_ground_min,
       round(100.0 * avg((next_dep_delay >= 15)::int), 1) AS pct_next_leg_late
FROM chained
WHERE arr_delay >= 0
GROUP BY inbound_delay_bucket
ORDER BY inbound_delay_bucket;

-- Correlation, one number for the writeup:
-- SELECT corr(arr_delay, next_dep_delay) FROM chained;   -- (inline the CTEs)


-- ---------------------------------------------------------------------------
-- Q5. Worst individual airframes -- the tail-number story
-- ---------------------------------------------------------------------------
SELECT f.tail_number,
       a.carrier_code,
       count(*)                                   AS legs,
       round(avg(f.arr_delay), 1)                 AS avg_arr_delay,
       round(100.0 * avg((f.arr_delay >= 15)::int), 1) AS pct_late,
       count(DISTINCT f.route_id)                 AS distinct_routes
FROM flights f
JOIN airlines a USING (airline_id)
WHERE f.tail_number IS NOT NULL AND NOT f.cancelled
GROUP BY f.tail_number, a.carrier_code
HAVING count(*) >= 300
ORDER BY avg_arr_delay DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- Q6. Seasonality: monthly on-time rate, and does weather explain the dips?
-- ---------------------------------------------------------------------------
SELECT date_trunc('month', f.flight_date)::date  AS month,
       count(*)                                  AS flights,
       round(100.0 * avg((f.arr_delay < 15)::int)
             FILTER (WHERE NOT f.cancelled), 1)  AS on_time_pct,
       round(100.0 * avg(f.cancelled::int), 2)   AS cancel_pct,
       round(avg(d.weather_delay), 2)            AS avg_weather_min_per_delayed
FROM flights f
LEFT JOIN delay_causes d USING (flight_id)
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- Q7. Route-level table: busiest routes and their reliability
-- ---------------------------------------------------------------------------
SELECT o.iata_code AS origin,
       dst.iata_code AS dest,
       r.distance_miles,
       count(*) AS flights,
       round(avg(f.arr_delay), 1) AS avg_arr_delay,
       round(avg(f.actual_elapsed_time - f.crs_elapsed_time), 1) AS avg_sched_padding
FROM flights f
JOIN routes   r   ON r.route_id  = f.route_id
JOIN airports o   ON o.airport_id = r.origin_airport_id
JOIN airports dst ON dst.airport_id = r.dest_airport_id
WHERE NOT f.cancelled
GROUP BY o.iata_code, dst.iata_code, r.distance_miles
ORDER BY flights DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- Q8. Cancellation reasons by month -- uses the lookup table
-- ---------------------------------------------------------------------------
SELECT date_trunc('month', f.flight_date)::date AS month,
       c.description,
       count(*) AS cancellations
FROM flights f
JOIN cancellation_codes c ON c.code = f.cancellation_code
WHERE f.cancelled
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
