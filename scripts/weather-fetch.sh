#!/bin/bash

set -euo pipefail

latitude=${1:-}
longitude=${2:-}
mode=${3:-}
user_agent=${MET_WEATHER_USER_AGENT:-"foamy-weather/1.1.0 (+https://github.com/foamrider/foamy-weather)"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}/omarchy-weather
cache_max_age=${MET_WEATHER_CACHE_MAX_AGE:-1800}

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

for dependency in curl jq date stat awk; do
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
if [[ -f $forecast_cache ]] && jq -e '.type == "Feature" and (.properties.timeseries | length > 0)' "$forecast_cache" >/dev/null 2>&1; then
  cache_age=$(($(date +%s) - $(stat -c %Y "$forecast_cache")))
  if (( cache_age < cache_max_age )); then
    cache_is_fresh=true
  fi
fi

stale=false
if [[ $mode == --force || $cache_is_fresh == false ]]; then
  forecast_url="https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=${latitude}&lon=${longitude}"
  if curl --fail --silent --show-error --compressed --connect-timeout 3 --max-time 10 \
    --user-agent "$user_agent" "$forecast_url" -o "$forecast_temp" 2>/dev/null \
    && jq -e '.type == "Feature" and (.properties.timeseries | length > 0)' "$forecast_temp" >/dev/null 2>&1; then
    chmod 600 "$forecast_temp"
    mv "$forecast_temp" "$forecast_cache"
  elif [[ -f $forecast_cache ]] && jq -e '.type == "Feature" and (.properties.timeseries | length > 0)' "$forecast_cache" >/dev/null 2>&1; then
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

  if [[ ! -f $sun_cache ]] || ! jq -e '.properties.sunrise.time and .properties.sunset.time' "$sun_cache" >/dev/null 2>&1; then
    sun_url="https://api.met.no/weatherapi/sunrise/3.0/sun?lat=${latitude}&lon=${longitude}&date=${forecast_date}"
    if curl --fail --silent --show-error --compressed --connect-timeout 3 --max-time 8 \
      --user-agent "$user_agent" "$sun_url" -o "$sun_temp" 2>/dev/null \
      && jq -e '.properties.sunrise.time and .properties.sunset.time' "$sun_temp" >/dev/null 2>&1; then
      chmod 600 "$sun_temp"
      mv "$sun_temp" "$sun_cache"
    fi
  fi

  if [[ -f $sun_cache ]]; then
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
