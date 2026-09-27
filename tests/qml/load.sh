#!/bin/bash
# Load test: runs the widget in its own Quickshell (tests/qml/harness.qml)
# with a stand-in bar that runs nothing, calls every IPC function, and fails
# on any QML warning or error. Safe at any time — even with the screen
# locked: the running Omarchy shell and Hyprland's windows aren't touched.
#
#   tests/qml/load.sh             top / left / bottom bar
#   tests/qml/load.sh --windows   also edge-case windows: odd titles (empty,
#                                 1000 chars, emoji/RTL/newline, markup) and
#                                 a title changing ~100×/s. These are probe
#                                 windows parked on special:minimized, so
#                                 the real taskbar lists them for a moment too.
set -uo pipefail
WINDOWS=0; [[ ${1:-} == --windows ]] && WINDOWS=1
PROBE=taskbox-probe

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHELL_DIR=${OMARCHY_PATH:-/usr/share/omarchy}/shell
command -v qs >/dev/null || { echo "qs (Quickshell) not found"; exit 2; }
[[ -d $SHELL_DIR ]] || { echo "Omarchy shell not found at $SHELL_DIR"; exit 2; }

# Quickshell only loads files from inside the config folder: assemble one
# with Omarchy's modules (qs.Commons, qs.Ui) and a copy of the plugin.
TMP=$(mktemp -d)
QS_PID=""
probes() { hyprctl clients -j | jq -r --arg c "$PROBE" '.[] | select(.class == $c) | .address'; }
cleanup() {
  [[ -n $QS_PID ]] && kill "$QS_PID" 2>/dev/null
  if ((WINDOWS)); then
    for a in $(probes); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
ln -s "$SHELL_DIR/Commons" "$TMP/Commons"
ln -s "$SHELL_DIR/Ui" "$TMP/Ui"
mkdir "$TMP/taskbox"
(cd "$ROOT" && tar --exclude=.git --exclude=tests -cf - .) | tar -xf - -C "$TMP/taskbox"
cp "$ROOT/tests/qml/harness.qml" "$TMP/shell.qml"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \e[31m✗ %s\e[0m\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
ipc() { timeout 3 qs ipc -p "$TMP/shell.qml" call mourningazazel.taskbox "$@" 2>&1; }

for position in top left bottom; do
  echo "load ($position bar)"
  TB_POSITION=$position qs -p "$TMP/shell.qml" >"$TMP/log" 2>&1 &
  QS_PID=$!
  for _ in $(seq 1 40); do ipc state >/dev/null 2>&1 && break; sleep 0.25; done
  sleep 1

  S=$(ipc state)
  if jq -e 'type == "array" and length == 1' >/dev/null 2>&1 <<<"$S"; then ok "state answers"; else bad "state answers" "$S"; fi
  [[ $(jq -r '.[0].vertical' <<<"$S") == $([[ $position == left ]] && echo true || echo false) ]] \
    && ok "bar orientation" || bad "bar orientation" "$(jq -c '.[0] | {vertical, barSize}' <<<"$S")"
  [[ $(jq -r '.[0].integrated' <<<"$S") == false ]] && ok "stays off Hyprland (stand-in bar runs nothing)" || bad "stays off Hyprland"
  [[ $(jq -r '.[0].preview.mode' <<<"$S") == all ]] && ok "settings reach the widget" || bad "settings reach the widget"
  for call in check "hover ''" "preview ''" "previewFailure false" "menu 0x1" "click 0x1" overflow settings colorPicker closePopups "icon foot" dropTargets; do
    out=$(eval ipc "$call")
    if [[ $out == *"No such"* || $out == *"rror"* ]]; then bad "ipc $call" "$out"; else ok "ipc $call"; fi
  done
  [[ $(ipc icon org.mozilla.firefox | jq -r '.candidates | length') -ge 1 ]] && ok "icon lookup explains itself" || bad "icon lookup explains itself"

  kill "$QS_PID" 2>/dev/null; wait "$QS_PID" 2>/dev/null; QS_PID=""
  PROBLEMS=$(grep -E "WARN|ERROR|FATAL|TypeError|ReferenceError|[Bb]inding loop" "$TMP/log" \
    | grep -vE "portal|notification server|Registration will be attempted|polkit" \
    | grep -v "\[taskbox\] unavailable here" || true)   # expected: no Lua, no bar slot here
  [[ -z $PROBLEMS ]] && ok "no QML warnings or errors" || bad "no QML warnings or errors" "$(head -5 <<<"$PROBLEMS")"
done

if ((WINDOWS)); then
  echo "edge-case windows"
  # Titles are set with the terminal's title escape, then the probe parks on
  # special:minimized (unknown origin: listed on every taskbar).
  spawn() {  # spawn <title-setting shell snippet>
    printf '%s\n' "$1" > "$TMP/probe-$((++n)).sh"
    hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a $PROBE sh $TMP/probe-$n.sh\", { workspace = \"special:minimized silent\" })" >/dev/null
  }
  n=0
  LONG=$(printf 'long%.0s' $(seq 1 250))
  spawn "printf '\\033]2;\\007'; sleep 600"
  spawn "printf '\\033]2;$LONG\\007'; sleep 600"
  spawn "printf '\\033]2;🚀 مرحبا\\nnext line ✓\\007'; sleep 600"
  spawn "printf '\\033]2;<b>bold</b> <img src=x>\\007'; sleep 600"
  spawn "i=0; while :; do i=\$((i+1)); printf '\\033]2;storm %s\\007' \$i; sleep 0.01; done"
  for _ in $(seq 1 50); do [[ $(probes | wc -l) -ge 5 ]] && break; sleep 0.2; done

  TB_POSITION=top qs -p "$TMP/shell.qml" >"$TMP/log" 2>&1 &
  QS_PID=$!
  for _ in $(seq 1 40); do ipc state >/dev/null 2>&1 && break; sleep 0.25; done
  sleep 2
  S=$(ipc state)
  W=$(jq -c --argjson p "$(probes | jq -R . | jq -s .)" '[.[0].windows[] | select(.address as $a | $p | index($a))]' <<<"$S")
  [[ $(jq length <<<"$W") -eq 5 ]] && ok "all 5 edge-case windows listed" || bad "all 5 edge-case windows listed" "$(jq -c '[.[] | .title]' <<<"$W")"
  [[ $(jq '[.[] | select(.title == "")] | length' <<<"$W") -ge 1 ]] && ok "an empty title is listed (the button falls back to the app id)" || bad "empty title"
  [[ $(jq --arg l "$LONG" '[.[] | select(.title == $l) | .titleVisible] | .[0]' <<<"$W") == false ]] \
    && ok "a 1000-character title is cut off (→ tooltip)" || bad "long title cut off" "$(jq -c '[.[] | {t: .title[:20], titleVisible}]' <<<"$W")"
  [[ $(jq '[.[] | select(.title | test("🚀"))] | length' <<<"$W") -eq 1 ]] && ok "emoji / right-to-left / newline title intact" || bad "unicode title"
  [[ $(jq '[.[] | select(.title | test("<b>bold</b>"))] | length' <<<"$W") -eq 1 ]] && ok "markup in a title stays text" || bad "markup title"

  # CPU while one window retitles itself ~100×/s: the harness's own cost.
  STORM=$(jq -r '[.[] | select(.title | startswith("storm"))][0].address' <<<"$W")
  t0=$(awk '{print $14 + $15}' /proc/$QS_PID/stat); sleep 5; t1=$(awk '{print $14 + $15}' /proc/$QS_PID/stat)
  CPU=$(( (t1 - t0) * 100 / $(getconf CLK_TCK) / 5 ))
  TITLES=$(ipc state | jq -r --arg a "$STORM" '.[0].windows[] | select(.address == $a) | .title')
  [[ $TITLES == storm* ]] && ok "the retitling window's button keeps up ($TITLES)" || bad "retitling window" "$TITLES"
  ((CPU < 25)) && ok "retitle storm costs ${CPU}% of a core (< 25%)" || bad "retitle storm costs ${CPU}% of a core" "expected < 25%"

  # A window that just moved (its minimize animation resizes it, and grim
  # 1.5.0 crashes if a window resizes mid-capture) waits until it settled.
  hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a $PROBE sleep 600\", { workspace = \"special:taskboxprobe silent\" })" >/dev/null
  for _ in $(seq 1 50); do [[ $(probes | wc -l) -ge 6 ]] && break; sleep 0.2; done
  FRESH=$(comm -13 <(jq -r '.[].address' <<<"$W" | sort) <(probes | sort) | head -1)
  sleep 1.5
  hyprctl dispatch "hl.dsp.window.move({ workspace = \"special:minimized\", follow = false, window = \"address:$FRESH\" })" >/dev/null
  sleep 0.2
  C0=$(ipc state | jq .[0].preview.captures)
  R=$(ipc preview "$FRESH")
  [[ $R == ok ]] || bad "preview of the just-moved window" "$R"
  sleep 0.5
  EARLY=$(ipc state | jq .[0].preview.captures)
  sleep 1.5
  LATE=$(ipc state | jq .[0].preview.captures)
  [[ $EARLY -eq $C0 && $LATE -eq $((C0 + 1)) ]] && ok "a just-moved window is captured only once it has settled (~1 s)" \
    || bad "a just-moved window is captured only once it has settled" "captures: before $C0, at 0.5 s $EARLY, at 2 s $LATE"
  ipc preview "" >/dev/null

  # A window closing while its preview is up / being captured.
  ipc preview "$STORM" >/dev/null
  hyprctl dispatch "hl.dsp.window.close({ window = \"address:$STORM\" })" >/dev/null
  sleep 1.5
  [[ $(ipc state | jq -r '.[0].preview.shown') == false ]] && ok "closing a previewed window hides its card" || bad "closing a previewed window hides its card"

  kill "$QS_PID" 2>/dev/null; wait "$QS_PID" 2>/dev/null; QS_PID=""
  PROBLEMS=$(grep -E "WARN|ERROR|FATAL|TypeError|ReferenceError|[Bb]inding loop" "$TMP/log" \
    | grep -vE "portal|notification server|Registration will be attempted|polkit" \
    | grep -v "\[taskbox\] unavailable here" || true)
  [[ -z $PROBLEMS ]] && ok "no QML warnings or errors" || bad "no QML warnings or errors" "$(head -5 <<<"$PROBLEMS")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
