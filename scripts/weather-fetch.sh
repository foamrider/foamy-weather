#!/bin/bash

set -euo pipefail

latitude=${1:-}
longitude=${2:-}
mode=${3:-}
user_agent=${MET_WEATHER_USER_AGENT:-"foamy-weather/1.1.0 (+https://github.com/foamrider/foamy-weather)"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}/omarchy-weather
cache_max_age=${MET_WEATHER_CACHE_MAX_AGE:-1800}
# Bound decoded responses, including caches written by older plugin versions.
forecast_max_bytes=$((2 * 1024 * 1024))
sun_max_bytes=$((64 * 1024))

json_error() {
  jq -cn --arg error "$1" '{error: $error}'
}

valid_coordinates() {
  awk -v lat="$1" -v lon="$2" 'BEGIN {
    numeric = lat ~ /^-?[0-9]+([.][0-9]+)?$/ && lon ~ /^-?[0-9]+([.][0-9]+)?$/
    in_range = lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    exit !(numeric && in_range)
  }'
}

file_is_bounded() {
  local file=$1 limit=$2 size
  [[ -f $file ]] || return 1
  size=$(stat -c %s -- "$file") || return 1
  ((size > 0 && size <= limit))
}

valid_forecast() {
  file_is_bounded "$1" "$forecast_max_bytes" &&
    jq -se 'length == 1 and (.[0] | .type == "Feature" and
      (.properties.timeseries | type == "array" and length > 0))' "$1" >/dev/null 2>&1
}

valid_sun() {
  file_is_bounded "$1" "$sun_max_bytes" &&
    jq -se 'length == 1 and (.[0] |
      (.properties.sunrise.time | type == "string" and length > 0) and
      (.properties.sunset.time | type == "string" and length > 0))' "$1" >/dev/null 2>&1
}

download_bounded() {
  local url=$1 output=$2 limit=$3 timeout=$4
  # Limit curl's decoded stdout independently of headers and compression. The
  # extra byte detects overflow even when the truncated prefix is valid JSON.
  # pipefail also rejects HTTP, transport, decompression, and write failures.
  if curl --fail --silent --show-error --compressed --connect-timeout 3 --max-time "$timeout" \
    --user-agent "$user_agent" "$url" 2>/dev/null | head -c "$((limit + 1))" >"$output"; then
    file_is_bounded "$output" "$limit"
  else
    return 1
  fi
}

for dependency in curl jq date stat awk head; do
  if ! command -v "$dependency" >/dev/null; then
    json_error "Mangler: $dependency"
    exit 0
  fi
done

if ! valid_coordinates "$latitude" "$longitude"; then
  json_error "Velg et sted for å hente værdata"
  exit 0
fi

# MET asks clients to limit coordinate precision so shared caches remain useful.
latitude=$(awk -v value="$latitude" 'BEGIN { printf "%.4f", value }')
longitude=$(awk -v value="$longitude" 'BEGIN { printf "%.4f", value }')
cache_key=${latitude}_${longitude}
cache_key=${cache_key//[^0-9A-Za-z._-]/_}

mkdir -p "$cache_root"
chmod 700 "$cache_root"

# Keep complete responses separate so an older compact cache cannot hide UV data.
forecast_cache="$cache_root/forecast-complete-${cache_key}.json"
forecast_temp=$(mktemp "$cache_root/.forecast.XXXXXX")
sun_temp=$(mktemp "$cache_root/.sun.XXXXXX")
sun_bundle=$(mktemp "$cache_root/.sun-bundle.XXXXXX")
trap 'rm -f "$forecast_temp" "$sun_temp" "$sun_bundle"' EXIT

cache_is_fresh=false
if valid_forecast "$forecast_cache"; then
  cache_age=$(($(date +%s) - $(stat -c %Y "$forecast_cache")))
  if (( cache_age < cache_max_age )); then
    cache_is_fresh=true
  fi
fi

stale=false
if [[ $mode == --force || $cache_is_fresh == false ]]; then
  forecast_url="https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=${latitude}&lon=${longitude}"
  if download_bounded "$forecast_url" "$forecast_temp" "$forecast_max_bytes" 10 \
    && valid_forecast "$forecast_temp"; then
    chmod 600 "$forecast_temp"
    mv "$forecast_temp" "$forecast_cache"
  elif valid_forecast "$forecast_cache"; then
    # A failed refresh must not replace useful conditions with an empty panel.
    stale=true
  else
    json_error "Værdata er utilgjengelig"
    exit 0
  fi
fi

: >"$sun_bundle"
for offset in 0 1 2; do
  forecast_date=$(date -d "+${offset} day" +%Y-%m-%d)
  sun_cache="$cache_root/sun-${cache_key}-${forecast_date}.json"

  sun_valid=false
  if valid_sun "$sun_cache"; then
    sun_valid=true
  else
    sun_url="https://api.met.no/weatherapi/sunrise/3.0/sun?lat=${latitude}&lon=${longitude}&date=${forecast_date}"
    if download_bounded "$sun_url" "$sun_temp" "$sun_max_bytes" 8 \
      && valid_sun "$sun_temp"; then
      chmod 600 "$sun_temp"
      mv "$sun_temp" "$sun_cache"
      sun_valid=true
    fi
  fi

  # An invalid old cache must not reach jq when its replacement also failed.
  if [[ $sun_valid == true ]]; then
    jq -c --arg date "$forecast_date" '{
      date: $date,
      sunrise: (.properties.sunrise.time // ""),
      sunset: (.properties.sunset.time // "")
    }' "$sun_cache" >>"$sun_bundle"
  else
    jq -cn --arg date "$forecast_date" '{date: $date, sunrise: "", sunset: ""}' >>"$sun_bundle"
  fi
done

fetched_at=$(date -Iseconds -d "@$(stat -c %Y "$forecast_cache")")
jq -s '.' "$sun_bundle" >"$sun_temp"
jq -cn \
  --slurpfile forecast "$forecast_cache" \
  --slurpfile sun "$sun_temp" \
  --arg fetchedAt "$fetched_at" \
  --argjson stale "$stale" \
  '{forecast: $forecast[0], sun: $sun[0], fetchedAt: $fetchedAt, stale: $stale}'

# Sun data is immutable for the requested date; retain only a small rolling set.
find "$cache_root" -maxdepth 1 -type f -name 'sun-*.json' -mtime +7 -delete 2>/dev/null || true
