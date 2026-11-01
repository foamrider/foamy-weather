#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
qsb_bin=${QSB:-/usr/lib/qt6/bin/qsb}
if [[ ! -x "$qsb_bin" ]]; then
  printf 'Qt Shader Baker is missing: %s (set QSB to its path)\n' "$qsb_bin" >&2
  exit 1
fi
"$qsb_bin" --glsl '330,300 es' -c \
  -o "$plugin_dir/shaders/atmosphere.frag.qsb" "$plugin_dir/shaders/atmosphere.frag"
