#!/bin/bash

set -euo pipefail

action=${1:-}
name=${2:-}
latitude=${3:-}
longitude=${4:-}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}/omarchy
location_file="$config_root/weather-location.local.json"

valid_coordinates() {
  awk -v lat="$1" -v lon="$2" 'BEGIN {
    numeric = lat ~ /^-?[0-9]+([.][0-9]+)?$/ && lon ~ /^-?[0-9]+([.][0-9]+)?$/
    in_range = lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    exit !(numeric && in_range)
  }'
}

mkdir -p "$config_root"

if [[ $action == --clear ]]; then
  rm -f "$location_file"
  exit 0
fi

if [[ $action != --set ]] || [[ -z $name ]] || ! valid_coordinates "$latitude" "$longitude"; then
  echo "Usage: weather-location.sh --set NAME LATITUDE LONGITUDE | --clear" >&2
  exit 2
fi

temp_file=$(mktemp "$config_root/.weather-location.XXXXXX")
trap 'rm -f "$temp_file"' EXIT
jq -n \
  --arg name "$name" \
  --argjson latitude "$latitude" \
  --argjson longitude "$longitude" \
  '{name: $name, latitude: $latitude, longitude: $longitude}' >"$temp_file"
chmod 600 "$temp_file"
mv "$temp_file" "$location_file"
