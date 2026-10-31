#!/bin/bash

set -euo pipefail
umask 077

latitude=""
longitude=""
mode=${1:-}
user_agent=${MET_WEATHER_USER_AGENT:-"foamy-weather/1.2.0 (+https://github.com/foamrider/foamy-weather)"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}/omarchy-weather
# Used only when MET sent no Expires header; Expires is honoured otherwise
# (capped at six hours). --force still waits for a minimum age between
# downloads so repeated refresh clicks don't send repeated full requests.
cache_max_age=${MET_WEATHER_CACHE_MAX_AGE:-1800}
force_min_age=${MET_WEATHER_FORCE_MIN_AGE:-60}
expires_max_age=21600
# Bound decoded responses, including caches written by older plugin versions.
forecast_max_bytes=$((2 * 1024 * 1024))
sun_max_bytes=$((64 * 1024))

# Errors are English translation keys; %1… values travel separately.
json_error() {
  local error=$1
  shift
  jq -cn --arg error "$error" '{error: $error, values: $ARGS.positional}' --args -- "$@"
}

valid_coordinates() {
  printf '%s\n' "$1" "$2" | awk 'NR == 1 {lat = $0} NR == 2 {lon = $0} END {
    numeric = lat ~ /^-?[0-9]+([.][0-9]+)?$/ && lon ~ /^-?[0-9]+([.][0-9]+)?$/
    in_range = lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    exit !(numeric && in_range)
  }'
}

file_is_bounded() {
  local file=$1 limit=$2 size
  [[ -f $file ]] || return 1
  # A legacy cache path contains coordinates; only expose its open descriptor.
  size=$(stat -Lc %s /dev/stdin <"$file") || return 1
  ((size > 0 && size <= limit))
}

valid_forecast() {
  file_is_bounded "$1" "$forecast_max_bytes" &&
    jq -se 'length == 1 and (.[0] | .type == "Feature" and
      (.properties.timeseries | type == "array" and length > 0))' <"$1" >/dev/null 2>&1
}

valid_sun() {
  file_is_bounded "$1" "$sun_max_bytes" &&
    jq -se 'length == 1 and (.[0] |
      (.properties.sunrise.time | type == "string" and length > 0) and
      (.properties.sunset.time | type == "string" and length > 0))' <"$1" >/dev/null 2>&1
}

download_bounded() {
  local url=$1 output=$2 limit=$3 timeout=$4
  # Limit curl's decoded stdout independently of headers and compression. The
  # extra byte detects overflow even when the truncated prefix is valid JSON.
  # pipefail also rejects HTTP, transport, decompression, and write failures.
  # curl reads the coordinate-bearing URL from stdin, never from its argv.
  if printf 'url = "%s"\n' "$url" | curl --fail --silent --show-error --compressed --connect-timeout 3 --max-time "$timeout" \
    --user-agent "$user_agent" --config - 2>/dev/null | head -c "$((limit + 1))" >"$output"; then
    file_is_bounded "$output" "$limit"
  else
    return 1
  fi
}

if ! command -v jq >/dev/null; then
  printf '%s\n' '{"error":"Missing required program: %1","values":["jq"]}'
  exit 0
fi
for dependency in curl date stat awk head sha256sum; do
  if ! command -v "$dependency" >/dev/null; then
    json_error "Missing required program: %1" "$dependency"
    exit 0
  fi
done

if (($# > 1)) || [[ -n $mode && $mode != --force ]] \
  || ! IFS= read -r latitude || ! IFS= read -r longitude \
  || ! valid_coordinates "$latitude" "$longitude"; then
  json_error "Choose a location to load weather"
  exit 0
fi

# MET asks clients to limit coordinate precision so shared caches remain
# useful. Three decimals (about 100 m) loses nothing for a forecast and
# discloses less than MET's four-decimal maximum.
legacy_latitude=$(awk '{ printf "%.4f", $0 }' <<<"$latitude")
legacy_longitude=$(awk '{ printf "%.4f", $0 }' <<<"$longitude")
latitude=$(awk '{ printf "%.3f", $0 }' <<<"$latitude")
longitude=$(awk '{ printf "%.3f", $0 }' <<<"$longitude")
# Opaque names keep coordinates out of filesystem-tool arguments too.
cache_key=$(printf '%s_%s' "$latitude" "$longitude" | sha256sum)
cache_key=${cache_key%% *}
# Versions up to 1.1 hashed the four-decimal coordinates.
legacy_cache_key=$(printf '%s_%s' "$legacy_latitude" "$legacy_longitude" | sha256sum)
legacy_cache_key=${legacy_cache_key%% *}

mkdir -p "$cache_root"
chmod 700 "$cache_root"

# Keep complete responses separate so an older compact cache cannot hide UV data.
forecast_cache="$cache_root/forecast-complete-${cache_key}.json"
# Expires (epoch) and Last-Modified of the cached forecast, one per line.
forecast_meta="$cache_root/forecast-complete-${cache_key}.meta"
forecast_temp=$(mktemp "$cache_root/.forecast.XXXXXX")
headers_temp=$(mktemp "$cache_root/.headers.XXXXXX")
meta_temp=$(mktemp "$cache_root/.meta.XXXXXX")
sun_temp=$(mktemp "$cache_root/.sun.XXXXXX")
sun_bundle=$(mktemp "$cache_root/.sun-bundle.XXXXXX")
trap 'rm -f "$forecast_temp" "$sun_temp" "$sun_bundle" "$headers_temp" "$meta_temp"' EXIT

# Read old coordinate-named caches through private descriptors, preserving age.
# Try the 1.1 hashed name, then the older coordinate-named one.
for legacy_forecast_cache in "$cache_root/forecast-complete-${legacy_cache_key}.json" \
  "$cache_root/forecast-complete-${legacy_latitude}_${legacy_longitude}.json"; do
  [[ ! -e $forecast_cache ]] && valid_forecast "$legacy_forecast_cache" || continue
  cat <"$legacy_forecast_cache" >"$forecast_temp"
  touch --reference=/dev/fd/3 "$forecast_temp" 3<"$legacy_forecast_cache"
  mv "$forecast_temp" "$forecast_cache"
done

header_value() {
  # The last response's header $1, without CR; empty when absent.
  awk -v name="$1" 'BEGIN { name = tolower(name) ":" }
    /^HTTP\// { value = "" }
    tolower($1) == name { sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); value = $0 }
    END { print value }' "$headers_temp"
}

# Remember MET's Expires and Last-Modified for the next request. $1 is the
# validator to keep when the response sends none (a 304 for an unchanged
# forecast); a new 200 body passes nothing.
save_meta() {
  local expires last_modified now fallback=${1:-}
  now=$(date +%s)
  expires=$(header_value expires)
  expires=$(date -d "$expires" +%s 2>/dev/null) || expires=""
  [[ $expires =~ ^[0-9]+$ ]] && ((expires > now)) || expires=""
  [[ -z $expires ]] || ((expires <= now + expires_max_age)) || expires=$((now + expires_max_age))
  last_modified=$(header_value last-modified)
  [[ -n $last_modified ]] || last_modified=$fallback
  # It is echoed into curl's config: accept only an HTTP date.
  [[ $last_modified =~ ^[A-Za-z0-9\ ,:+-]{1,64}$ ]] || last_modified=""
  printf '%s\n%s\n' "$expires" "$last_modified" >"$meta_temp"
  chmod 600 "$meta_temp"
  mv "$meta_temp" "$forecast_meta"
}

# Prints 200, 304 or nothing (failure); the body goes to $forecast_temp.
download_forecast() {
  local url=$1 last_modified=$2 status
  : >"$headers_temp"
  if {
    printf 'url = "%s"\n' "$url"
    [[ -z $last_modified ]] || printf 'header = "If-Modified-Since: %s"\n' "$last_modified"
  } | curl --fail --silent --show-error --compressed --connect-timeout 3 --max-time 10 \
    --user-agent "$user_agent" --dump-header "$headers_temp" --config - 2>/dev/null \
    | head -c "$((forecast_max_bytes + 1))" >"$forecast_temp"; then
    status=$(awk '/^HTTP\// { code = $2 } END { print code }' "$headers_temp")
    if [[ $status == 304 ]]; then
      printf '304'
    elif file_is_bounded "$forecast_temp" "$forecast_max_bytes" && valid_forecast "$forecast_temp"; then
      printf '200'
    fi
  fi
}

cache_is_fresh=false
cache_valid=false
cached_expires=""
cached_last_modified=""
if valid_forecast "$forecast_cache"; then
  cache_valid=true
  now=$(date +%s)
  cache_age=$((now - $(stat -c %Y "$forecast_cache")))
  if [[ -f $forecast_meta ]]; then
    cached_expires=$(sed -n 1p "$forecast_meta")
    cached_last_modified=$(sed -n 2p "$forecast_meta")
    [[ $cached_expires =~ ^[0-9]+$ ]] || cached_expires=""
    [[ $cached_last_modified =~ ^[A-Za-z0-9\ ,:+-]{1,64}$ ]] || cached_last_modified=""
  fi
  if [[ $mode == --force ]]; then
    ((cache_age < force_min_age)) && cache_is_fresh=true
  elif [[ -n $cached_expires ]]; then
    ((now < cached_expires)) && cache_is_fresh=true
  elif ((cache_age < cache_max_age)); then
    cache_is_fresh=true
  fi
fi

stale=false
if [[ $cache_is_fresh == false ]]; then
  forecast_url="https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=${latitude}&lon=${longitude}"
  [[ $cache_valid == true ]] || cached_last_modified=""
  forecast_status=$(download_forecast "$forecast_url" "$cached_last_modified")
  if [[ $forecast_status == 200 ]]; then
    chmod 600 "$forecast_temp"
    mv "$forecast_temp" "$forecast_cache"
    save_meta
  elif [[ $forecast_status == 304 ]]; then
    # Unchanged on MET's side: the cached forecast is current again.
    touch "$forecast_cache"
    save_meta "$cached_last_modified"
  elif valid_forecast "$forecast_cache"; then
    # A failed refresh must not replace useful conditions with an empty panel.
    stale=true
  else
    json_error "Weather data is unavailable"
    exit 0
  fi
fi

: >"$sun_bundle"
for offset in 0 1 2; do
  forecast_date=$(date -d "+${offset} day" +%Y-%m-%d)
  sun_cache="$cache_root/sun-${cache_key}-${forecast_date}.json"
  for legacy_sun_cache in "$cache_root/sun-${legacy_cache_key}-${forecast_date}.json" \
    "$cache_root/sun-${legacy_latitude}_${legacy_longitude}-${forecast_date}.json"; do
    [[ ! -e $sun_cache ]] && valid_sun "$legacy_sun_cache" || continue
    cat <"$legacy_sun_cache" >"$sun_temp"
    touch --reference=/dev/fd/3 "$sun_temp" 3<"$legacy_sun_cache"
    mv "$sun_temp" "$sun_cache"
  done

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
