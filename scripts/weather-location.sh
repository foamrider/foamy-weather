#!/bin/bash

set -euo pipefail

action=${1:-}
# The searched place is state, next to Omarchy's own weather.json. Older
# versions kept it in config; --migrate moves it.
state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}/omarchy/settings
location_file="$state_root/foamy-weather-location.json"
legacy_file=${XDG_CONFIG_HOME:-"$HOME/.config"}/omarchy/weather-location.local.json

# Validate boundary data before writing; the whole location stays in stdin.
read_location() {
  jq -sce 'select(length == 1) | .[0] | select(type == "object" and
    (.name | type == "string" and length > 0) and
    (.latitude | type == "number" and . >= -90 and . <= 90) and
    (.longitude | type == "number" and . >= -180 and . <= 180)) |
    {name: .name, latitude: .latitude, longitude: .longitude}'
}

# An owner-only temp file in the same directory, renamed into place.
# --no-clobber links it instead, which fails if the file appeared meanwhile.
write_location() {
  mkdir -p "$state_root"
  temp_file=$(mktemp "$state_root/.foamy-weather-location.XXXXXX")
  trap 'rm -f "$temp_file"' EXIT
  printf '%s\n' "$1" >"$temp_file"
  chmod 600 "$temp_file"
  if [[ ${2:-} == --no-clobber ]]; then
    ln -T -- "$temp_file" "$location_file" 2>/dev/null || return 1
  else
    mv "$temp_file" "$location_file"
  fi
}

if [[ $action == --clear ]]; then
  rm -f "$location_file" "$legacy_file"
  exit 0
fi

# Copy a valid legacy file to state, check the copy, and only then remove the
# legacy file. A valid state file wins and the legacy file goes; an invalid
# legacy file, or an invalid state file, is left alone.
if [[ $action == --migrate && $# == 1 ]]; then
  [[ -f $legacy_file ]] || exit 0
  if [[ -e $location_file ]]; then
    if read_location <"$location_file" >/dev/null 2>&1; then rm -f "$legacy_file"; fi
    exit 0
  fi
  location=$(read_location <"$legacy_file" 2>/dev/null) || exit 0
  # Lost a race with --set: its pick wins, the next run removes the legacy file.
  write_location "$location" --no-clobber || exit 0
  [[ $(read_location <"$location_file" 2>/dev/null) == "$location" ]] || exit 1
  rm -f "$legacy_file"
  exit 0
fi

if [[ $action != --set || $# != 1 ]]; then
  echo "Usage: weather-location.sh --set < location.json | --clear | --migrate" >&2
  exit 2
fi

if ! location=$(read_location); then
  echo "Invalid location" >&2
  exit 2
fi

write_location "$location"
