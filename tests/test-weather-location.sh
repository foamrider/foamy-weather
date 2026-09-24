#!/bin/bash

set -euo pipefail

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

plugin_root=$(cd -- "$(dirname "$0")/.." && pwd)
resolver="$plugin_root/scripts/weather-resolve-location.sh"
location_writer="$plugin_root/scripts/weather-location.sh"
mock_bin="$test_root/bin"
mkdir -p "$mock_bin" "$test_root/config" "$test_root/cache" "$test_root/runtime"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$mock_bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' '{"address":{"town":"Example Town"}}'
EOF

cat >"$mock_bin/where-am-i" <<'EOF'
#!/bin/bash
printf '%s\n' 'Latitude: 12.3456°' 'Longitude: 56.7890°'
EOF

chmod +x "$mock_bin"/*

export PATH="$mock_bin:$PATH"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_CACHE_HOME="$test_root/cache"
export WEATHER_LOCATION_RUNTIME_DIR="$test_root/runtime"
export WEATHER_GEOCLUE_COMMAND="$mock_bin/where-am-i"
location_file="$XDG_CONFIG_HOME/omarchy/weather-location.local.json"

"$location_writer" --set Example 12.34 56.78
manual=$(cat "$location_file")
jq -e '
  .name == "Example"
  and .latitude == 12.34
  and .longitude == 56.78' <<<"$manual" >/dev/null || fail "manual location did not persist"

"$location_writer" --clear
[[ ! -e $location_file ]] || fail "manual location was not cleared"

geoclue=$("$resolver" --force)
jq -e '
  .name == "Example Town"
  and .latitude == 12.3456
  and .longitude == 56.7890
  and .source == "geoclue"' <<<"$geoclue" >/dev/null || fail "GeoClue fallback was not resolved"

cached=$("$resolver")
jq -e '.name == "Example Town" and .source == "geoclue-cache"' <<<"$cached" >/dev/null \
  || fail "fresh GeoClue location was not read from cache"

unavailable=$(WEATHER_GEOCLUE_COMMAND="$test_root/missing" "$resolver" --force)
jq -e '.error == "Kunne ikke finne automatisk posisjon"' <<<"$unavailable" >/dev/null \
  || fail "unavailable GeoClue must report an error"

# Invalid coordinates and failed preference validation must preserve saved files.
"$location_writer" --set Example 12 34
if "$location_writer" --set Invalid 91 0 2>/dev/null; then fail "invalid latitude accepted"; fi
jq -e '.name == "Example"' "$location_file" >/dev/null || fail "invalid location replaced saved location"
# Validate and route writes through Omarchy rather than writing shell.json ourselves.
cat >"$mock_bin/omarchy" <<'EOF'
#!/bin/bash
jq -cn '$ARGS.positional' --args -- "$@" >>"$WEATHER_TEST_CALLS"
exit "${WEATHER_TEST_STATUS:-0}"
EOF
chmod +x "$mock_bin/omarchy"
export WEATHER_TEST_CALLS="$test_root/settings-calls.jsonl"
preferences_writer="$plugin_root/scripts/weather-preferences.sh"
"$preferences_writer" example.weather language '"en"'
"$preferences_writer" example.weather automaticLocation false
jq -se '.[0] == ["bar","set","example.weather","language","\"en\"","--json"] and .[1] == ["bar","set","example.weather","automaticLocation","false","--json"]' "$WEATHER_TEST_CALLS" >/dev/null || fail "wrong shell settings arguments"
if "$preferences_writer" example.weather language '"unsupported"' 2>/dev/null; then fail "invalid preference accepted"; fi
if "$preferences_writer" example.weather id '"different.widget"' 2>/dev/null; then fail "unknown preference accepted"; fi
[[ $(wc -l <"$WEATHER_TEST_CALLS") == 2 ]] || fail "invalid settings reached the shell"
if WEATHER_TEST_STATUS=9 "$preferences_writer" example.weather animations true; then fail "shell failure was swallowed"; fi
printf '%s\n' "Weather location and shell settings tests passed."
