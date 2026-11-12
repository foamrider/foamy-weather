#!/bin/bash
# The location helpers as processes: bin/<arch>/foamy-weather-helper, or the
# JSON argv prefix in FOAMY_HELPER (tests/fakenet.py). Network
# requests go to a loopback HTTPS stand-in, never to Nominatim.

set -euo pipefail

test_root=$(mktemp -d)
server_pid=""
trap '[[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null; rm -rf "$test_root"' EXIT

plugin_root=$(cd -- "$(dirname "$0")/.." && pwd)
helper_argv() {
  mapfile -d '' -t "$1" < <(python3 "$plugin_root/tests/fakenet.py" argv "$2" </dev/null)
}
helper_argv resolver resolve-location
helper_argv location_writer location
mock_bin="$test_root/bin"
mkdir -p "$mock_bin" "$test_root/config" "$test_root/cache" "$test_root/runtime" "$test_root/net"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

printf '%s\n' '{"address":{"town":"Example Town"}}' >"$test_root/net/reverse.json"
python3 "$plugin_root/tests/fakenet.py" serve "$test_root/net" &
server_pid=$!
for _ in $(seq 100); do [[ -e $test_root/net/port ]] && break; sleep 0.1; done
[[ -e $test_root/net/port ]] || fail "the loopback server did not start"
for variable in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY SSL_CERT_DIR; do
  unset "$variable"
done
export FOAMY_WEATHER_TEST_CONNECT="127.0.0.1:$(cat "$test_root/net/port")"
export SSL_CERT_FILE="$test_root/net/ca.pem"

cat >"$mock_bin/where-am-i" <<'EOF'
#!/bin/bash
printf '%s\n' 'Latitude: 12.3456°' 'Longitude: 56.7890°'
EOF

chmod +x "$mock_bin"/*

export PATH="$mock_bin:$PATH"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_STATE_HOME="$test_root/state"
export XDG_CACHE_HOME="$test_root/cache"
export WEATHER_LOCATION_RUNTIME_DIR="$test_root/runtime"
export WEATHER_GEOCLUE_COMMAND="$mock_bin/where-am-i"
location_file="$XDG_STATE_HOME/omarchy/settings/foamy-weather-location.json"
legacy_file="$XDG_CONFIG_HOME/omarchy/weather-location.local.json"
mkdir -p "$(dirname "$legacy_file")"

"${location_writer[@]}" --set <<<'{"name":"Example","latitude":12.34,"longitude":56.78}'
manual=$(cat "$location_file")
jq -e '
  .name == "Example"
  and .latitude == 12.34
  and .longitude == 56.78' <<<"$manual" >/dev/null || fail "manual location did not persist"
[[ $(stat -c %a "$location_file") == 600 ]] || fail "manual location must be owner-only"
[[ ! -e $legacy_file ]] || fail "manual location must not be written to config"

rm -f "$location_file"

# Migration: a valid legacy file moves to state once, owner-only.
"${location_writer[@]}" --migrate || fail "migrate without any file must succeed"
[[ ! -e $location_file ]] || fail "migrate without a legacy file created a location"
printf '%s\n' '{"name":"Old Town","latitude":59.91,"longitude":10.75,"extra":true}' >"$legacy_file"
chmod 644 "$legacy_file"
"${location_writer[@]}" --migrate || fail "migrate failed"
jq -e '. == {name: "Old Town", latitude: 59.91, longitude: 10.75}' "$location_file" >/dev/null \
  || fail "legacy location was not migrated"
[[ $(stat -c %a "$location_file") == 600 ]] || fail "migrated location must be owner-only"
[[ ! -e $legacy_file ]] || fail "legacy location was not removed after migrating"
[[ -z $(find "$XDG_STATE_HOME/omarchy/settings" -name '.*') ]] || fail "migrate left a temp file"

# Both present: the state file wins and the legacy file goes.
printf '%s\n' '{"name":"Stale","latitude":1,"longitude":2}' >"$legacy_file"
"${location_writer[@]}" --migrate || fail "migrate with both files failed"
jq -e '.name == "Old Town"' "$location_file" >/dev/null || fail "legacy location replaced the state location"
[[ ! -e $legacy_file ]] || fail "superseded legacy location was not removed"

# An invalid legacy file is left alone, and so is an unreadable state file.
rm -f "$location_file" "$legacy_file"
printf '%s\n' '{"name":"Broken","latitude":91,"longitude":2}' >"$legacy_file"
"${location_writer[@]}" --migrate || fail "migrate with an invalid legacy file must succeed"
[[ ! -e $location_file ]] || fail "invalid legacy location was migrated"
jq -e '.name == "Broken"' "$legacy_file" >/dev/null || fail "invalid legacy location was changed"
printf '%s\n' '{"name":"Old","latitude":1,"longitude":2}' >"$legacy_file"
printf '%s\n' '{broken' >"$location_file"
"${location_writer[@]}" --migrate || fail "migrate with an invalid state file must succeed"
[[ $(cat "$location_file") == '{broken' ]] || fail "invalid state location was overwritten"
jq -e '.name == "Old"' "$legacy_file" >/dev/null || fail "legacy location removed without a valid state location"
rm -f "$location_file" "$legacy_file"

# Usage errors: exit 2, nothing written or removed. `--clear` had no caller
# and was removed; it must not delete the files any more.
printf '%s\n' '{"name":"Old","latitude":1,"longitude":2}' >"$legacy_file"
for usage in "--bogus" "--set extra" "--clear"; do
  set +e
  # shellcheck disable=SC2086
  "${location_writer[@]}" $usage </dev/null 2>/dev/null
  status=$?
  set -e
  [[ $status == 2 ]] || fail "usage error '$usage' must exit 2 (got $status)"
done
[[ ! -e $location_file ]] || fail "a usage error wrote a location"
[[ -e $legacy_file ]] || fail "a usage error removed the legacy location"
rm -f "$legacy_file"

geoclue=$("${resolver[@]}" --force)
jq -e '
  .name == "Example Town"
  and .latitude == 12.35
  and .longitude == 56.79
  and .source == "geoclue"' <<<"$geoclue" >/dev/null || fail "GeoClue location was not resolved and rounded to about 1 km"
grep -q 'lat=12.35&lon=56.79&' "$test_root/net/requests" || fail "Nominatim must get the rounded coordinates"
if grep -q '12.3456\|56.789' "$test_root/net/requests"; then fail "precise coordinates reached Nominatim"; fi
[[ $(stat -c %a "$test_root/runtime") == 700 ]] || fail "the runtime directory must be owner-only"
[[ $(stat -c %a "$test_root/runtime/current-location.json") == 600 ]] || fail "the position must be owner-only"

cached=$("${resolver[@]}")
jq -e '.name == "Example Town" and .source == "geoclue-cache"' <<<"$cached" >/dev/null \
  || fail "fresh GeoClue location was not read from cache"
requests=$(wc -l <"$test_root/net/requests")
# The label cache answers a forced lookup of the same place.
"${resolver[@]}" --force >/dev/null
[[ $(wc -l <"$test_root/net/requests") == "$requests" ]] || fail "a cached place name was requested again"

unavailable=$(WEATHER_GEOCLUE_COMMAND="$test_root/missing" "${resolver[@]}" --force)
jq -e '.error == "Could not find automatic location"' <<<"$unavailable" >/dev/null \
  || fail "unavailable GeoClue must report an error"

# Invalid coordinates and failed preference validation must preserve saved files.
"${location_writer[@]}" --set <<<'{"name":"Example","latitude":12,"longitude":34}'
if "${location_writer[@]}" --set <<<'{"name":"Invalid","latitude":91,"longitude":0}' 2>/dev/null; then fail "invalid latitude accepted"; fi
jq -e '.name == "Example"' "$location_file" >/dev/null || fail "invalid location replaced saved location"
# No private runtime directory: fail instead of falling back to /tmp.
no_runtime=$(env -u XDG_RUNTIME_DIR -u WEATHER_LOCATION_RUNTIME_DIR "${resolver[@]}" --force)
jq -e '.error == "Automatic location needs XDG_RUNTIME_DIR"' <<<"$no_runtime" >/dev/null \
  || fail "missing XDG_RUNTIME_DIR must not fall back to /tmp"
mkdir -m 700 "$test_root/xdg-runtime"
from_xdg=$(env -u WEATHER_LOCATION_RUNTIME_DIR XDG_RUNTIME_DIR="$test_root/xdg-runtime" "${resolver[@]}" --force)
jq -e '.source == "geoclue"' <<<"$from_xdg" >/dev/null || fail "XDG_RUNTIME_DIR was not used"
[[ -f $test_root/xdg-runtime/omarchy-weather-$UID/current-location.json ]] \
  || fail "the position must live in \$XDG_RUNTIME_DIR/omarchy-weather-\$UID"
ln -s "$test_root/runtime" "$test_root/runtime-link"
linked=$(WEATHER_LOCATION_RUNTIME_DIR="$test_root/runtime-link" "${resolver[@]}" --force)
jq -e '.error == "Automatic location storage is not private"' <<<"$linked" >/dev/null \
  || fail "a symlinked runtime directory must be refused"
unknown=$("${resolver[@]}" --bogus)
jq -e '.error == "Unknown option: %1" and .values == ["--bogus"]' <<<"$unknown" >/dev/null \
  || fail "errors must be English keys with separate values"
printf '%s\n' "Weather location tests passed."
