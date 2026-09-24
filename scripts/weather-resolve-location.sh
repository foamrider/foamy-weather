#!/bin/bash

set -euo pipefail

mode=${1:-}
user_agent=${WEATHER_LOCATION_USER_AGENT:-"foamy-weather/1.1.0 (+https://github.com/foamrider/foamy-weather)"}
runtime_root=${WEATHER_LOCATION_RUNTIME_DIR:-"${XDG_RUNTIME_DIR:-/tmp}/omarchy-weather-${UID}"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}/omarchy-weather
location_cache="$runtime_root/current-location.json"
location_cache_max_age=${WEATHER_LOCATION_CACHE_MAX_AGE:-900}
label_cache_max_age=${WEATHER_LOCATION_LABEL_CACHE_MAX_AGE:-604800}
geoclue_command=${WEATHER_GEOCLUE_COMMAND:-/usr/lib/geoclue-2.0/demos/where-am-i}

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

emit_location() {
  local name=$1
  local latitude=$2
  local longitude=$3
  local source=$4

  jq -cn \
    --arg name "$name" \
    --argjson latitude "$latitude" \
    --argjson longitude "$longitude" \
    --arg source "$source" \
    '{name: $name, latitude: $latitude, longitude: $longitude, source: $source}'
}

cached_geoclue_location() {
  local age name latitude longitude
  [[ -f $location_cache ]] || return 1

  age=$(($(date +%s) - $(stat -c %Y "$location_cache")))
  ((age < location_cache_max_age)) || return 1
  name=$(jq -r '.name // empty' "$location_cache" 2>/dev/null) || return 1
  latitude=$(jq -r '.latitude // empty' "$location_cache" 2>/dev/null) || return 1
  longitude=$(jq -r '.longitude // empty' "$location_cache" 2>/dev/null) || return 1
  [[ -n $latitude && -n $longitude ]] && valid_coordinates "$latitude" "$longitude" || return 1

  emit_location "$name" "$latitude" "$longitude" geoclue-cache
}

location_label() {
  local latitude=$1
  local longitude=$2
  local rounded_latitude rounded_longitude cache_key cache_file age label response

  rounded_latitude=$(awk -v value="$latitude" 'BEGIN {printf "%.2f", value}')
  rounded_longitude=$(awk -v value="$longitude" 'BEGIN {printf "%.2f", value}')
  cache_key=${rounded_latitude}_${rounded_longitude}
  cache_key=${cache_key//[^0-9A-Za-z._-]/_}
  cache_file="$cache_root/location-${cache_key}.json"

  if [[ -f $cache_file ]]; then
    age=$(($(date +%s) - $(stat -c %Y "$cache_file")))
    if ((age < label_cache_max_age)); then
      label=$(jq -r '.name // empty' "$cache_file" 2>/dev/null) || true
      if [[ -n $label ]]; then
        printf '%s' "$label"
        return 0
      fi
    fi
  fi

  response=""
  if command -v curl >/dev/null; then
    response=$(curl --fail --silent --show-error --compressed \
      --connect-timeout 3 --max-time 8 --user-agent "$user_agent" \
      "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${latitude}&lon=${longitude}&zoom=10&addressdetails=1" \
      2>/dev/null) || true
  fi
  label=$(jq -r '
    .address.city
    // .address.town
    // .address.village
    // .address.municipality
    // .address.county
    // empty' <<<"${response:-{}}" 2>/dev/null) || true
  [[ -n $label ]] || label="${rounded_latitude}, ${rounded_longitude}"

  jq -cn --arg name "$label" '{name: $name}' >"$cache_file"
  chmod 600 "$cache_file"
  printf '%s' "$label"
}

geoclue_location() {
  local output latitude longitude name temp_file

  if [[ $mode != --force ]] && cached_geoclue_location; then
    return 0
  fi
  [[ -x $geoclue_command ]] || return 1

  output=$(timeout 5 "$geoclue_command" 2>/dev/null || true)
  latitude=$(awk '/Latitude:/ {gsub(/,/, ".", $2); gsub(/[^0-9.+-]/, "", $2); print $2; exit}' <<<"$output")
  longitude=$(awk '/Longitude:/ {gsub(/,/, ".", $2); gsub(/[^0-9.+-]/, "", $2); print $2; exit}' <<<"$output")
  [[ -n $latitude && -n $longitude ]] && valid_coordinates "$latitude" "$longitude" || return 1

  # MET already limits forecast coordinates to four decimals; use the same
  # precision for labels and caches instead of disclosing extra precision.
  latitude=$(awk -v value="$latitude" 'BEGIN {printf "%.4f", value}')
  longitude=$(awk -v value="$longitude" 'BEGIN {printf "%.4f", value}')

  name=$(location_label "$latitude" "$longitude")
  temp_file=$(mktemp "$runtime_root/.current-location.XXXXXX")
  jq -cn \
    --arg name "$name" \
    --argjson latitude "$latitude" \
    --argjson longitude "$longitude" \
    '{name: $name, latitude: $latitude, longitude: $longitude}' >"$temp_file"
  chmod 600 "$temp_file"
  mv "$temp_file" "$location_cache"
  emit_location "$name" "$latitude" "$longitude" geoclue
}

for dependency in jq awk date stat timeout; do
  if ! command -v "$dependency" >/dev/null; then
    json_error "Mangler: $dependency"
    exit 0
  fi
done

mkdir -p "$runtime_root" "$cache_root"
chmod 700 "$runtime_root" "$cache_root"

if [[ $mode == --force ]]; then
  rm -f "$location_cache"
elif [[ -n $mode ]]; then
  json_error "Ukjent valg: $mode"
  exit 0
fi

if geoclue_location; then
  exit 0
fi

json_error "Kunne ikke finne automatisk posisjon"
