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
cat >>"$WEATHER_TEST_URLS"
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
export WEATHER_TEST_URLS="$test_root/urls"
location_file="$XDG_CONFIG_HOME/omarchy/weather-location.local.json"

"$location_writer" --set <<<'{"name":"Example","latitude":12.34,"longitude":56.78}'
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
  and .latitude == 12.35
  and .longitude == 56.79
  and .source == "geoclue"' <<<"$geoclue" >/dev/null || fail "GeoClue location was not resolved and rounded to about 1 km"
grep -q 'lat=12.35&lon=56.79&' "$WEATHER_TEST_URLS" || fail "Nominatim must get the rounded coordinates"
if grep -q '12.3456\|56.789' "$WEATHER_TEST_URLS"; then fail "precise coordinates reached Nominatim"; fi

cached=$("$resolver")
jq -e '.name == "Example Town" and .source == "geoclue-cache"' <<<"$cached" >/dev/null \
  || fail "fresh GeoClue location was not read from cache"

unavailable=$(WEATHER_GEOCLUE_COMMAND="$test_root/missing" "$resolver" --force)
jq -e '.error == "Could not find automatic location"' <<<"$unavailable" >/dev/null \
  || fail "unavailable GeoClue must report an error"

# Invalid coordinates and failed preference validation must preserve saved files.
"$location_writer" --set <<<'{"name":"Example","latitude":12,"longitude":34}'
if "$location_writer" --set <<<'{"name":"Invalid","latitude":91,"longitude":0}' 2>/dev/null; then fail "invalid latitude accepted"; fi
jq -e '.name == "Example"' "$location_file" >/dev/null || fail "invalid location replaced saved location"
# No private runtime directory: fail instead of falling back to /tmp.
no_runtime=$(env -u XDG_RUNTIME_DIR -u WEATHER_LOCATION_RUNTIME_DIR "$resolver" --force)
jq -e '.error == "Automatic location needs XDG_RUNTIME_DIR"' <<<"$no_runtime" >/dev/null \
  || fail "missing XDG_RUNTIME_DIR must not fall back to /tmp"
ln -s "$test_root/runtime" "$test_root/runtime-link"
linked=$(WEATHER_LOCATION_RUNTIME_DIR="$test_root/runtime-link" "$resolver" --force)
jq -e '.error == "Automatic location storage is not private"' <<<"$linked" >/dev/null \
  || fail "a symlinked runtime directory must be refused"
unknown=$("$resolver" --bogus)
jq -e '.error == "Unknown option: %1" and .values == ["--bogus"]' <<<"$unknown" >/dev/null \
  || fail "errors must be English keys with separate values"
printf '%s\n' "Weather location tests passed."
