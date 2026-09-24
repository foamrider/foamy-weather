#!/bin/bash
set -euo pipefail

widget_id=${1:-}
key=${2:-}
value=${3:-}
[[ -n $widget_id && $# == 3 ]] || { echo "Usage: weather-preferences.sh WIDGET_ID KEY JSON_VALUE" >&2; exit 2; }
case "$key" in
  language) filter='. == "nb" or . == "en"' ;;
  units) filter='. == "metric" or . == "imperial"' ;;
  automaticLocation|animations) filter='type == "boolean"' ;;
  *) echo "Unknown weather preference: $key" >&2; exit 2 ;;
esac
if ! jq -e "$filter" <<<"$value" >/dev/null; then
  echo "Invalid weather preference: $key" >&2
  exit 2
fi

# The shell owns both the active configuration and its persisted JSON.
exec omarchy bar set "$widget_id" "$key" "$value" --json
