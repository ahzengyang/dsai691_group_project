#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01_download.sh -- fetch BTS On-Time Performance monthly files + OurAirports
#
# Usage:   ./01_download.sh [START_YEAR] [START_MONTH] [END_YEAR] [END_MONTH]
# Default: 2025-01 .. 2025-12
#
# Data availability (verified Sept 2026): BTS publishes Jan 1995 - Jun 2026.
# Delay-cause columns (Carrier/Weather/NAS/Security/LateAircraft) exist only
# from June 2003 onward -- do not pick a range that starts before that.
# ---------------------------------------------------------------------------
set -euo pipefail

SY=${1:-2025}; SM=${2:-1}; EY=${3:-2025}; EM=${4:-12}

RAW="raw"
mkdir -p "$RAW"

BASE="https://transtats.bts.gov/PREZIP"
STEM="On_Time_Reporting_Carrier_On_Time_Performance_1987_present"

echo "==> BTS On-Time Performance: ${SY}-${SM} .. ${EY}-${EM}"

y=$SY; m=$SM
while [ "$y" -lt "$EY" ] || { [ "$y" -eq "$EY" ] && [ "$m" -le "$EM" ]; }; do
  f="${STEM}_${y}_${m}.zip"
  if [ -f "$RAW/$f" ]; then
    echo "    skip (already have) $f"
  else
    echo "    get  $f"
    # BTS is slow and occasionally 403s bare clients; UA header + retries help.
    curl -fSL --retry 4 --retry-delay 5 --connect-timeout 30 \
         -A "Mozilla/5.0 (university coursework; contact: you@example.edu)" \
         -o "$RAW/$f.part" "$BASE/$f" \
      && mv "$RAW/$f.part" "$RAW/$f" \
      || { echo "    !! FAILED $f  (see NOTE below)"; rm -f "$RAW/$f.part"; }
    sleep 2   # be polite; do not hammer a .gov host
  fi
  m=$((m+1)); if [ "$m" -gt 12 ]; then m=1; y=$((y+1)); fi
done

echo "==> OurAirports reference data (daily-refreshed, public domain)"
curl -fSL -o "$RAW/ourairports_airports.csv" \
  https://davidmegginson.github.io/ourairports-data/airports.csv
curl -fSL -o "$RAW/ourairports_countries.csv" \
  https://davidmegginson.github.io/ourairports-data/countries.csv

echo
echo "Downloaded into ./$RAW :"
du -sh "$RAW" 2>/dev/null || true
ls -1 "$RAW" | head -20
echo
cat <<'NOTE'
NOTE -- if the PREZIP downloads 403 or return an HTML error page:
  BTS sometimes blocks direct PREZIP access. Fallback is the interactive form:
    https://www.transtats.bts.gov/DL_SelectFields.asp?gnoyr_VQ=FGJ
  Pick a year+month, tick "Prezipped File" at the top right, download, and drop
  the resulting .zip into ./raw/ with any filename. 02_prepare.py globs *.zip,
  so it does not care what the files are called.
NOTE
