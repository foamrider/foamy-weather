#!/bin/bash

set -euo pipefail

action=${1:-}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}/omarchy
location_file="$config_root/weather-location.local.json"

mkdir -p "$config_root"

if [[ $action == --clear ]]; then
  rm -f "$location_file"
  exit 0
fi

if [[ $action != --set || $# != 1 ]]; then
  echo "Usage: weather-location.sh --set < location.json | --clear" >&2
  exit 2
fi

# Validate boundary data before writing; the whole location stays in stdin.
if ! location=$(jq -sce 'select(length == 1) | .[0] | select(type == "object" and
  (.name | type == "string" and length > 0) and
  (.latitude | type == "number" and . >= -90 and . <= 90) and
  (.longitude | type == "number" and . >= -180 and . <= 180)) |
  {name: .name, latitude: .latitude, longitude: .longitude}'); then
  echo "Invalid location" >&2
  exit 2
fi

temp_file=$(mktemp "$config_root/.weather-location.XXXXXX")
trap 'rm -f "$temp_file"' EXIT
printf '%s\n' "$location" >"$temp_file"
chmod 600 "$temp_file"
mv "$temp_file" "$location_file"
