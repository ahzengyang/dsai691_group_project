#!/usr/bin/env python3
"""
02_prepare.py -- turn the BTS monthly zips into ONE clean CSV with a fixed,
known column list, so the SQL schema never has to track BTS column drift.

The raw BTS extract has ~110 columns (including 25 diversion columns nobody
uses) and a trailing comma on every row that produces a phantom empty column.
We select a whitelist by NAME, so column reordering upstream cannot break us.

Output:  clean/flights.csv        (header row, UTF-8, RFC4180 quoting)
         clean/airports_ref.csv   (OurAirports, trimmed to US + columns we use)

Usage:   python3 02_prepare.py
"""
import csv, glob, io, os, sys, zipfile

RAW, CLEAN = "raw", "clean"
os.makedirs(CLEAN, exist_ok=True)
csv.field_size_limit(10_000_000)

# BTS column name  ->  our column name
COLS = {
    "FlightDate":                     "flight_date",
    "Reporting_Airline":              "carrier_code",
    "DOT_ID_Reporting_Airline":       "airline_id",
    "Flight_Number_Reporting_Airline":"flight_number",
    "Tail_Number":                    "tail_number",

    "OriginAirportID":                "origin_airport_id",
    "Origin":                         "origin_iata",
    "OriginCityName":                 "origin_city",
    "OriginState":                    "origin_state",
    "DestAirportID":                  "dest_airport_id",
    "Dest":                           "dest_iata",
    "DestCityName":                   "dest_city",
    "DestState":                      "dest_state",

    "CRSDepTime":                     "crs_dep_time",
    "DepTime":                        "dep_time",
    "DepDelay":                       "dep_delay",
    "DepDel15":                       "dep_del15",
    "TaxiOut":                        "taxi_out",
    "WheelsOff":                      "wheels_off",
    "WheelsOn":                       "wheels_on",
    "TaxiIn":                         "taxi_in",
    "CRSArrTime":                     "crs_arr_time",
    "ArrTime":                        "arr_time",
    "ArrDelay":                       "arr_delay",
    "ArrDel15":                       "arr_del15",

    "Cancelled":                      "cancelled",
    "CancellationCode":               "cancellation_code",
    "Diverted":                       "diverted",

    "CRSElapsedTime":                 "crs_elapsed_time",
    "ActualElapsedTime":              "actual_elapsed_time",
    "AirTime":                        "air_time",
    "Distance":                       "distance",

    "CarrierDelay":                   "carrier_delay",
    "WeatherDelay":                   "weather_delay",
    "NASDelay":                       "nas_delay",
    "SecurityDelay":                  "security_delay",
    "LateAircraftDelay":              "late_aircraft_delay",
}
OUT_HEADER = list(COLS.values())

# BTS writes 1.00 / 0.00 for flags; SQL wants a clean boolean-ish integer.
FLAGS = {"cancelled", "diverted", "dep_del15", "arr_del15"}
# hhmm fields: BTS uses "2400" for midnight, which no time type accepts.
HHMM  = {"crs_dep_time", "dep_time", "wheels_off", "wheels_on",
         "crs_arr_time", "arr_time"}


def norm(name, val):
    v = (val or "").strip()
    if v == "":
        return ""
    if name in FLAGS:
        try:
            return "1" if float(v) >= 0.5 else "0"
        except ValueError:
            return ""
    if name in HHMM:
        try:
            n = int(float(v))
        except ValueError:
            return ""
        if n == 2400:
            n = 0
        return f"{n:04d}"
    if name == "tail_number":
        return v.upper().replace(" ", "") or ""
    if name == "flight_date":
        return v[:10]          # BTS may append " 00:00:00"
    return v


def rows_from_zip(path):
    with zipfile.ZipFile(path) as z:
        members = [n for n in z.namelist() if n.lower().endswith(".csv")]
        if not members:
            print(f"  !! no csv inside {path}", file=sys.stderr)
            return
        with z.open(members[0]) as fh:
            # BTS files are latin-1; a handful of city names break strict utf-8.
            text = io.TextIOWrapper(fh, encoding="latin-1", newline="")
            rdr = csv.DictReader(text)
            missing = [c for c in COLS if c not in (rdr.fieldnames or [])]
            if missing:
                print(f"  !! {os.path.basename(path)} is missing: "
                      f"{', '.join(missing)}", file=sys.stderr)
                print("     (pre-2003 files have no delay-cause columns)",
                      file=sys.stderr)
            for r in rdr:
                yield [norm(out, r.get(src, "")) for src, out in COLS.items()]


def main():
    zips = sorted(glob.glob(os.path.join(RAW, "*.zip")))
    if not zips:
        sys.exit(f"No zips in ./{RAW}/ -- run 01_download.sh first.")

    out_path = os.path.join(CLEAN, "flights.csv")
    total = 0
    with open(out_path, "w", newline="", encoding="utf-8") as out:
        w = csv.writer(out, quoting=csv.QUOTE_MINIMAL)
        w.writerow(OUT_HEADER)
        for z in zips:
            n = 0
            for row in rows_from_zip(z):
                w.writerow(row); n += 1
            total += n
            print(f"  {os.path.basename(z):<70} {n:>9,} rows")
    print(f"\n  -> {out_path}  ({total:,} rows)")

    # ---- OurAirports: trim to the columns and rows we actually join on ------
    src = os.path.join(RAW, "ourairports_airports.csv")
    if os.path.exists(src):
        keep = ["ident", "type", "name", "latitude_deg", "longitude_deg",
                "elevation_ft", "iso_country", "iso_region", "municipality",
                "iata_code"]
        dst = os.path.join(CLEAN, "airports_ref.csv")
        kept = 0
        with open(src, encoding="utf-8", newline="") as f, \
             open(dst, "w", encoding="utf-8", newline="") as o:
            rdr = csv.DictReader(f)
            w = csv.writer(o)
            w.writerow(keep)
            for r in rdr:
                if r.get("iata_code") and r.get("iso_country") == "US":
                    w.writerow([r.get(k, "") for k in keep]); kept += 1
        print(f"  -> {dst}  ({kept:,} US airports with IATA codes)")
    else:
        print("  (no OurAirports file found; airport lat/long will be NULL)")


if __name__ == "__main__":
    main()
