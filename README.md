# U.S. Domestic Flight Delays — relational database project

Scheduled vs. actual times for every reportable U.S. domestic flight, with
delay causes, built into a normalized PostgreSQL schema.

**Source:** Bureau of Transportation Statistics, Airline On-Time Performance
Data (Reporting Carrier table). Airport geography from OurAirports.

```
01_download.sh   fetch BTS monthly zips + OurAirports        (network)
02_prepare.py    clean + pin the schema -> clean/flights.csv  (stdlib only)
03_schema.sql    DDL: staging + normalized tables
04_load.sql      \copy the clean CSVs into staging
05_transform.sql staging -> dimensions/fact, indexes, sanity checks
06_queries.sql   the analysis queries
```

Requirements: Python 3.8+, `curl`, `psql`. No pandas, no ORM, no pip install.

---

## Quick start

```bash
chmod +x 01_download.sh
./01_download.sh 2025 1 2025 12      # year/month start, year/month end
python3 02_prepare.py
createdb flights
psql -d flights -f 03_schema.sql
psql -d flights -f 04_load.sql       # run psql from THIS directory
psql -d flights -f 05_transform.sql
psql -d flights -f 06_queries.sql
```

`04_load.sql` uses `\copy`, which reads files client-side using paths relative
to your current directory. Run psql from the project directory, not elsewhere.

### Do one month first

`05_transform.sql` truncates before it loads, so it's safe to re-run. Start
with `./01_download.sh 2025 1 2025 1`, take it end to end, and confirm the
sanity checks at the bottom of stage 5 look right. Then download the full range
and re-run stages 2, 4, and 5. This beats finding a problem 40 minutes into a
full load.

---

## The schema

```
airlines ──┐
airports ──┼──< flights >──── delay_causes   (1:0..1)
aircraft ──┤        │
routes   ──┘        └──────── cancellation_codes
```

| table | grain | notes |
|---|---|---|
| `flights` | one scheduled flight leg | the fact table |
| `delay_causes` | one delayed arrival | only exists when a flight was late ≥15 min — a real 1:0..1, which is exactly why it's separate |
| `airlines` | one carrier | PK is the **DOT id**, not the two-letter code |
| `airports` | one airport | BTS surrogate id, enriched with lat/long/elevation |
| `routes` | one origin→dest pair | derived, not imported |
| `aircraft` | one tail number | |
| `cancellation_codes` | 4 rows | A/B/C/D from the BTS codebook |

Indexes are created *after* the bulk insert, which is substantially faster.
The partial index on `(tail_number, flight_date, crs_dep_time)` is what makes
the cascading-delay query tractable.

---

## Expected sizes

| range | rows | Postgres size w/ indexes |
|---|---|---|
| 1 month | ~500–600k | ~700 MB |
| 3 months | ~1.7M | ~2–3 GB |
| 12 months | ~6–7M | ~8–12 GB |

If your class server is tight on disk, three months is plenty — every query in
`06_queries.sql` still works, the numbers are just noisier. Twelve months is
what you want if you're doing the seasonality query.

---

## The queries (`06_queries.sql`)

1. On-time rankings by carrier — DOT's <15 min definition, with cancellation
   rate reported separately so an airline can't look punctual by cancelling
   its worst flights
2. Worst airports for departures, including average taxi-out
3. Weather vs. carrier vs. NAS vs. late-aircraft — share of total delay minutes
4. **Cascading delays** — chains legs by tail number within a day and measures
   how inbound delay propagates to the next departure, controlling for
   scheduled ground time. This is the centrepiece.
5. Worst individual airframes
6. Monthly seasonality
7. Busiest routes and their schedule padding
8. Cancellation reasons by month

---

## Things that will bite you

- **Delay-cause columns only exist from June 2003 onward.** Earlier files load
  fine but `delay_causes` comes out empty.
- **BTS writes `2400` for midnight**, which no SQL `time` type accepts.
  `02_prepare.py` folds it to `0000`.
- **The raw CSVs are latin-1**, not UTF-8, and carry a trailing comma that
  produces a phantom column. Both handled in prep.
- **Carrier codes are not stable across mergers.** American absorbed US Airways
  reporting in July 2015; Alaska absorbed Virgin America in April 2018. That's
  why `airlines` is keyed on the DOT id. If your date range crosses a merger,
  say so in the report — or stay within 2019+ and sidestep it.
- **Airline names are not in the extract.** `05_transform.sql` attaches them
  from a short seed list and prints any carrier it couldn't name, so you can
  add it. Don't skip that check — an unnamed regional will show up as
  `(unmapped)` in your results.
- **If PREZIP returns 403 or an HTML error page**, use the interactive picker at
  `https://www.transtats.bts.gov/DL_SelectFields.asp?gnoyr_VQ=FGJ` — tick
  "Prezipped File" at the top right and drop the zip into `raw/`.
  `02_prepare.py` globs `*.zip` and ignores filenames.
- **`02_prepare.py` selects columns by name**, so upstream reordering can't
  break the load. It warns loudly about anything missing.

---

## Optional: aircraft attributes

`aircraft` currently holds only the tail number, because BTS gives you nothing
else about the airframe. If you want "do older aircraft delay more," you need
the FAA Releasable Aircraft Database (the N-number registry) — free, separate
download, joins on N-number after stripping the leading `N` and whitespace.
Worth it only if you have time; the cascading-delay analysis is the stronger
story.

---

## Porting to MySQL or SQLite

Postgres is much less work here, but if you're forced off it:

- `GENERATED ALWAYS AS IDENTITY` → `AUTO_INCREMENT` (MySQL) or
  `INTEGER PRIMARY KEY AUTOINCREMENT` (SQLite)
- `\copy ... FORMAT csv` → `LOAD DATA LOCAL INFILE` (MySQL) or `.import --csv`
  (SQLite)
- SQLite has no `boolean` or `time` type — use `INTEGER` 0/1 and store times as
  `hhmm` text, and change the prep script's flag mapping accordingly
- `FILTER (WHERE ...)` → `avg(CASE WHEN ... THEN 1 ELSE 0 END)`
- `DISTINCT ON` → a `row_number()` subquery
- `percentile_cont` has no SQLite equivalent; substitute an average or compute
  the median by hand
- The window functions in Q4 work in MySQL 8+ and SQLite 3.25+

---

## Citations

- Bureau of Transportation Statistics, *Airline On-Time Performance Data*
  (Reporting Carrier On-Time Performance, 1987–present). Data available January
  1995 through June 2026. https://www.transtats.bts.gov/ontime/
  Public domain (U.S. federal government work).
- OurAirports open data. https://ourairports.com/data/ — public domain.
