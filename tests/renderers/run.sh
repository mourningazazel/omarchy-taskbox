#!/bin/bash
# The hover preview under different Qt renderers / GPU stacks.
#
#   tests/renderers/run.sh
#
# Runs the preview's display path (tests/renderers/shell.qml: the real capture
# script + a Qt Image) in a separate Quickshell process per renderer — the
# desktop's default, forced OpenGL ES, Vulkan, Qt's software renderer and
# Mesa's llvmpipe (software GL, like a VM or a machine without a working
# driver) — against a hidden probe window, and checks every renderer shows the
# same picture. The running shell is not touched. Renderers the machine can't
# start (e.g. no Vulkan driver) are skipped, not failed.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROBE=taskbox-probe
TMP=$(mktemp -d)
pass=0; fail=0; skipped=0
ok()   { pass=$((pass + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \e[31m✗ %s\e[0m\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
skip() { skipped=$((skipped + 1)); printf '  - %s (skipped: %s)\n' "$1" "$2"; }

probes() { hyprctl clients -j | jq -r --arg c "$PROBE" '.[] | select(.class == $c) | .address'; }
cleanup() {
  for a in $(probes); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; done
  [[ -n ${TASKBOX_KEEP:-} ]] && cp -r "$TMP" "$TASKBOX_KEEP"; rm -rf "$TMP"
}
trap cleanup EXIT

command -v qs >/dev/null || { echo "qs (Quickshell) not found"; exit 2; }
# Quickshell only loads files from inside the config folder: assemble one.
mkdir -p "$TMP/harness"
cp "$ROOT/tests/renderers/shell.qml" "$ROOT/lib/Logic.js" "$TMP/harness/"
before=$(probes | wc -l)
hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a $PROBE sh -c 'ls -l --color=always /usr/bin; sleep 900'\", { workspace = \"special:taskboxprobe silent\" })" >/dev/null
for _ in $(seq 1 50); do (( $(probes | wc -l) > before )) && break; sleep 0.2; done
ADDR=$(probes | tail -1)
[[ -n $ADDR ]] || { echo "probe window didn't appear"; exit 1; }
# A window launched straight onto a hidden workspace hasn't drawn yet: its
# first capture is blank, and prompts it to draw. Warm it up once, so every
# renderer gets the same picture. (Windows minimized the usual way were drawn
# on screen first, so their first capture already has content.)
sleep 1
grim -T "$(hyprctl clients -j | jq -r --arg a "$ADDR" '.[] | select(.address == $a) | .stableId')" "$TMP/warmup.png" 2>/dev/null
sleep 1

echo "renderers (probe $ADDR)"
reference=""
while IFS='|' read -r name vars; do
  out="$TMP/$name"; mkdir -p "$out"
  # shellcheck disable=SC2086
  env $vars TB_ADDR="$ADDR" TB_OUT="$out" timeout 15 qs -p "$TMP/harness/shell.qml" >"$out/log" 2>&1
  result=$(grep -o 'RESULT .*' "$out/log" | cut -d' ' -f2-)
  if [[ -z $result ]]; then
    if grep -qiE "vulkan|failed to create|could not initialize|no suitable" "$out/log"; then
      skip "$name" "renderer unavailable here: $(grep -iE 'vulkan|failed|could not' "$out/log" | head -1 | cut -c1-100)"
    else
      bad "$name: harness produced no result" "$(tail -3 "$out/log")"
    fi
    continue
  fi
  if [[ $(jq -r '.capture.exit' <<<"$result") != 0 || $(jq -r '.image // empty' <<<"$result") == "" || ! -s $out/shown.png ]]; then
    bad "$name: capture shown" "$result"; continue
  fi
  sum=$(sha256sum <"$out/shown.png" | cut -c1-16)
  # Different renderers may round differently; compare decoded pixels loosely
  # when ImageMagick is there, exactly otherwise.
  if [[ -z $reference ]]; then
    reference=$out/shown.png
    ok "$name ($(jq -r .api <<<"$result")): picture shown, capture $(jq .capture.ms <<<"$result") ms"
  elif command -v magick >/dev/null; then
    diff=$(magick compare -metric RMSE "$reference" "$out/shown.png" null: 2>&1 | grep -oE '\(([0-9.e-]+)\)' | tr -d '()')
    if awk -v d="${diff:-1}" 'BEGIN { exit !(d < 0.02) }'; then
      ok "$name ($(jq -r .api <<<"$result")): same picture (RMSE ${diff}), capture $(jq .capture.ms <<<"$result") ms"
    else
      bad "$name: picture differs from the default renderer's" "RMSE $diff"
    fi
  else
    ok "$name ($(jq -r .api <<<"$result")): picture shown ($sum), capture $(jq .capture.ms <<<"$result") ms"
  fi
done <<'LIST'
default|
opengl-es|QT_OPENGL=es2 QSG_RHI_BACKEND=opengl
vulkan|QSG_RHI_BACKEND=vulkan
software|QT_QUICK_BACKEND=software
llvmpipe|LIBGL_ALWAYS_SOFTWARE=1
LIST

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
((fail == 0))
