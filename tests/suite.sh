#!/bin/bash
# foamy-weather's own tests; tests/validate.sh runs this after the linters.
#   --ci    no Quickshell, no Omarchy host: node, and the helper against the
#           loopback stand-ins (bin/x86_64, and bin/aarch64 too where this
#           machine can run it)
#   --fast  skip the offscreen runtime tests
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
ci=0 fast=0
for arg in "$@"; do
  case $arg in
    --ci) ci=1 ;;
    --fast) fast=1 ;;
    *)
      echo "suite.sh: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done
status=0
run() {
  echo "== $*"
  "$@" || status=1
}
skip() { echo "SKIP $*"; }
# test_clipboard's QML part starts a Quickshell.
((ci)) && export FOAMY_TESTS_NO_QUICKSHELL=1

# The helper tests, on this machine's helper and then the other one.
helper_tests() {
  run node --test tests/weather-fetch.test.js
  run bash tests/test-weather-location.sh
  run python3 -m unittest tests.test_location_privacy
}
for test in tests/*.test.js tests/i18n.test.cjs; do
  [[ $test == tests/weather-fetch.test.js ]] || run node "$test"
done
helper_tests
run python3 -m unittest tests.test_clipboard
other=x86_64
[[ $(uname -m) == x86_64 ]] && other=aarch64
# A usage error exits 2 when the binary runs (qemu binfmt for the other arch).
"bin/$other/foamy-weather-helper" location --bogus </dev/null >/dev/null 2>&1
if (($? == 2)); then
  # No core files from the emulator in the plugin tree.
  (
    ulimit -c 0
    export FOAMY_HELPER="[\"$PWD/bin/$other/foamy-weather-helper\"]"
    echo "== the $other helper"
    helper_tests
    exit "$status"
  ) || status=1
else
  skip "the $other helper: this machine can't run it (qemu binfmt)"
fi
if ((ci || fast)); then
  skip "runtime.py, search-runtime.py, fetch-runtime.py, sky-gpu.py and the kit's i18n_runtime.py: offscreen Quickshell"
else
  # The same default as the runtime tests'.
  export FOAMY_KIT="${FOAMY_KIT:-$HOME/GitHub/Personal/foamy-kit}"
  run python3 tests/runtime.py
  run python3 tests/search-runtime.py
  run python3 tests/fetch-runtime.py
  run python3 tests/sky-gpu.py
  run python3 "$FOAMY_KIT/preview/i18n_runtime.py" .
fi
exit $status
