#!/bin/bash
# Live integration tests: run against the real shell + Hyprland session.
#
#   tests/live/run.sh          safe checks (a few seconds of dimmed test buttons)
#   tests/live/run.sh --full   also reloads Hyprland, restarts the shell and
#                              disables/re-enables Taskbox (recovery/cleanup)
#   tests/live/run.sh --facade run in Omarchy 4.0.4+ mode: Taskbox only gets
#                              the restricted plugin facade (BarFacade.qml)
#   (flags combine)
#
# Safety: every window action targets throwaway "probe" windows (class
# taskbox-probe / a test web app) that live on hidden special workspaces or
# are parked as "minimized", so they never take a tile or focus. Settings,
# popups, hover and the active workspace are restored on exit, even on failure.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ID=$(jq -r .id "$ROOT/manifest.json")
FULL=0; FACADE=0
for arg in "$@"; do
  case $arg in
    --full) FULL=1 ;;
    --facade) FACADE=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done
PROBE=taskbox-probe
SHELL_JSON=$HOME/.config/omarchy/shell.json
TMP=$(mktemp -d)

pass=0; fail=0; skipped=0
ok()   { pass=$((pass + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \e[31m✗ %s\e[0m\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
skip() { skipped=$((skipped + 1)); printf '  - %s (skipped: %s)\n' "$1" "$2"; }
section() { printf '\n%s\n' "$1"; }

check() {  # check "name" command...
  local name=$1; shift
  local out
  if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$out"; fi
}

# ---------------------------------------------------------------- helpers

ipc() { omarchy-shell "$ID" "$@"; }
state() { ipc state; }
# First instance on the focused monitor (the one tests look at).
here() { state | jq --argjson ws "$(hyprctl activeworkspace -j | jq .id)" '[.[] | select(.workspace == $ws)][0]'; }

wait_for() {  # wait_for <seconds> <bash condition>
  local deadline=$((SECONDS + $1)); shift
  until eval "$@"; do
    ((SECONDS >= deadline)) && return 1
    sleep 0.2
  done
}

lua() { hyprctl dispatch "$1" >/dev/null; }

probes() { hyprctl clients -j | jq -r --arg c "$PROBE" '.[] | select(.class == $c) | .address'; }
client() { hyprctl clients -j | jq -c --arg a "$1" '.[] | select(.address == $a)'; }

# Refuse to act on anything that isn't one of our probe windows.
probe_only() {
  local class
  class=$(client "$1" | jq -r '.class // empty')
  [[ $class == "$PROBE" || $class == chrome-example.com* ]] || { echo "refusing: $1 is '$class', not a probe"; exit 99; }
}

act() {  # act <Taskbox function> <probe address> [more args]
  local fn=$1 address=$2; shift 2
  probe_only "$address"
  local args="\"$address\""
  for a in "$@"; do args+=", \"$a\""; done
  lua "Taskbox.$fn($args)"
}

# Launch through Hyprland with the placement attached to the launch itself:
# the window maps straight onto a hidden special workspace, never on screen
# and never focused. (A class-matching window rule is too late for apps that
# set their class after mapping, e.g. Chromium.)
launch_hidden() {  # launch_hidden <workspace> <command>
  hyprctl dispatch "hl.dsp.exec_cmd(\"$2\", { workspace = \"$1 silent\" })" >/dev/null
}

spawn_probes() {  # spawn_probes <n>: hidden on special:taskboxprobe
  local target=$(( $(probes | wc -l) + $1 ))
  for ((i = 0; i < $1; i++)); do
    launch_hidden special:taskboxprobe "foot -a $PROBE sleep 900"
    sleep 0.25   # distinct open order
  done
  wait_for 10 "[[ \$(probes | wc -l) -ge $target ]]"
}

park() {  # park <address>: onto special:minimized without a known origin
  probe_only "$1"
  lua "hl.dsp.window.move({ workspace = \"special:minimized\", follow = false, window = \"address:$1\" })"
}

close_probes() {
  for a in $(probes); do lua "hl.dsp.window.close({ window = \"address:$a\" })"; done
  wait_for 5 '[[ -z $(probes) ]]' || pkill -f "^foot -a $PROBE" || true
}

# ---------------------------------------------------------------- baseline + cleanup

START_WS=$(hyprctl activeworkspace -j | jq .id)
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
ORIG_POS=$(jq -r '.bar.position // "top"' "$SHELL_JSON")
ORIG_ENTRY=$(jq -c --arg id "$ID" '[.bar.layout[]?[]? | select(.id == $id)][0] // empty' "$SHELL_JSON")
[[ -n $ORIG_ENTRY ]] || { echo "$ID is not on the bar; enable it first"; exit 2; }
TOUCHED=(maxWidth minWidth showTitle emulateFacade highlightColor preview)

cleanup() {
  ipc hover "" >/dev/null 2>&1
  ipc preview "" >/dev/null 2>&1
  ipc previewFailure false >/dev/null 2>&1
  ipc closePopups >/dev/null 2>&1
  close_probes
  pkill -f -- "--user-data-dir=$TMP/chrome" 2>/dev/null
  rm -f "$HOME/.local/share/applications/taskbox-test-webapp.desktop"
  # Put back only the settings we changed (omarchy bar set can't delete keys,
  # so a key that wasn't set goes back to its default).
  if ! jq -e --arg id "$ID" '[.bar.layout[]?[]? | select(.id == $id)] | length > 0' "$SHELL_JSON" >/dev/null; then
    omarchy plugin enable "$ID" >/dev/null 2>&1
    omarchy bar move "$ID" --section right --index 0 >/dev/null 2>&1
  fi
  for key in "${TOUCHED[@]}"; do
    local value
    value=$(jq -c --arg k "$key" '.[$k] // empty' <<<"$ORIG_ENTRY")
    [[ -z $value ]] && value=$(jq -c --arg k "$key" '.barWidget.defaults[$k] // false' "$ROOT/manifest.json")
    if [[ $value == \"* ]]; then omarchy bar set "$ID" "$key" "$(jq -r . <<<"$value")" >/dev/null 2>&1
    else omarchy bar set "$ID" "$key" "$(jq -r . <<<"$value")" --json >/dev/null 2>&1; fi
  done
  [[ $(jq -r '.bar.position // "top"' "$SHELL_JSON") == "$ORIG_POS" ]] || omarchy bar position "$ORIG_POS" >/dev/null 2>&1
  [[ $(hyprctl activeworkspace -j | jq .id) == "$START_WS" ]] || lua "hl.dsp.focus({ workspace = \"$START_WS\" })"
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------- tests

if ((FACADE)); then
  omarchy bar set "$ID" emulateFacade true --json >/dev/null
  wait_for 8 '[[ $(here | jq .facade) == true && $(here | jq .integrated) == true ]]'
fi

section "integration$( ((FACADE)) && echo ' (4.0.4 plugin facade)')"
S=$(here)
check "running $( ((FACADE)) && echo 'behind the plugin facade' || echo 'with the host bar')" test "$(jq .facade <<<"$S")" = "$( ((FACADE)) && echo true || echo false)"
check "found its bar slot by walking its parents" test "$(jq .slotFound <<<"$S")" = true
check "found the bar's sections by walking its window" test "$(jq .barSlots <<<"$S")" -ge 3
check "IPC answers with one snapshot per bar" test "$(state | jq length)" -ge 1
check "Hyprland side attached" test "$(jq -r .integrated <<<"$S")" = true
check "self-check finds nothing missing" test "$(ipc check)" = "[]"
check "Lua version matches manifest" test "$(jq -r .version <<<"$S")" = "$(jq -r .version "$ROOT/manifest.json")"
check "4 Alt binds" test "$(hyprctl binds -j | jq '[.[] | select(.key | test("^Alt_[LR]$"))] | length')" -eq 4
check "one shell process" test "$(pgrep -xc quickshell)" -eq 1

section "window model (parked probe windows)"
BASE=$(jq '.windows | length' <<<"$S")
spawn_probes 3
mapfile -t P < <(probes)
for a in "${P[@]}"; do park "$a"; done
check "3 parked probes appear on this taskbar" wait_for 5 '[[ $(here | jq ".windows | length") -eq $((BASE + 3)) ]]'
S=$(here)
check "they're marked minimized" test "$(jq --argjson n "$BASE" '[.windows[$n:][] | .minimized] | all' <<<"$S")" = true
check "newest on the right (opening order)" test \
  "$(jq -r --argjson n "$BASE" '[.windows[$n:][] | .address] | join(" ")' <<<"$S")" = "$(printf '%s\n' "${P[@]}" | tr '\n' ' ' | sed 's/ $//')"
check "sizes fit the available space" test "$(jq '(.fitCount * .buttonExtent + ([.fitCount - 1, 0] | max) * 4) <= .available' <<<"$S")" = true

section "tooltips only when the title is cut off"
LONG="taskbox-probe-with-a-title-far-too-long-for-any-taskbar-button-to-show-in-full"
launch_hidden special:taskboxprobe "foot -a $PROBE -T $LONG sleep 900"
wait_for 10 '[[ -n $(hyprctl clients -j | jq -r --arg t "$LONG" ".[] | select(.title == \$t) | .address") ]]'
L=$(hyprctl clients -j | jq -r --arg t "$LONG" '.[] | select(.title == $t) | .address')
park "$L"
wait_for 5 '[[ $(here | jq --arg a "$L" "any(.windows[]; .address == \$a)") == true ]]'
sleep 0.5   # layout
check "a short title that fits needs no tooltip" test "$(here | jq --arg a "${P[0]}" '.windows[] | select(.address == $a) | .titleVisible')" = true
check "a truncated title gets one" test "$(here | jq --arg a "$L" '.windows[] | select(.address == $a) | .titleVisible')" = false
omarchy bar set "$ID" showTitle false --json >/dev/null
check "with titles off, every button gets one" wait_for 5 '[[ $(here | jq "[.windows[] | select(.shown) | .titleVisible] | any") == false ]]'
omarchy bar set "$ID" showTitle "$(jq -r '.showTitle // true' <<<"$ORIG_ENTRY")" --json >/dev/null
lua "hl.dsp.window.close({ window = \"address:$L\" })"
wait_for 5 '[[ $(here | jq --arg a "$L" "any(.windows[]; .address == \$a)") == false ]]'

section "minimize conventions of other plugins"
spawn_probes 1
Q=$(comm -13 <(printf '%s\n' "${P[@]}" | sort) <(probes | sort) | head -1)
probe_only "$Q"
lua "hl.dsp.window.move({ workspace = \"special:omarchy-minimized\", follow = false, window = \"address:$Q\" })"
check "window-shelf / qol-desktop-plus minimized windows show, dimmed" wait_for 5 '[[ $(here | jq --arg a "$Q" "[.windows[] | select(.address == \$a and .minimized)] | length") -eq 1 ]]'
act close_or_kill "$Q"
check "the × closes gracefully when Alt isn't held" wait_for 5 '[[ -z $(client "$Q") ]]'

section "overflow"
omarchy bar set "$ID" minWidth 300 --json >/dev/null
check "narrow space overflows into +N" wait_for 5 '[[ $(here | jq .overflowing) == true ]]'
S=$(here)
check "hidden windows are exactly the overflow" test "$(jq '([.windows[] | select(.shown | not)] | length) == ((.windows | length) - .fitCount)' <<<"$S")" = true
check "the focused window stays visible" test "$(jq '[.windows[] | select(.active)] | all(.shown)' <<<"$S")" = true
check "overflow list opens" test "$(ipc overflow)" = overflow
ipc closePopups >/dev/null
omarchy bar set "$ID" minWidth "$(jq -r '.minWidth // 44' <<<"$ORIG_ENTRY")" --json >/dev/null
check "back to no overflow" wait_for 5 '[[ $(here | jq .overflowing) == false ]]'

section "settings"
omarchy bar set "$ID" showTitle false --json >/dev/null
check "settings changes reach the widget" wait_for 5 '[[ $(here | jq .settings.showTitle) == false ]]'
omarchy bar set "$ID" maxWidth 5 --json >/dev/null
check "out-of-range values are clamped" wait_for 5 '[[ $(here | jq .settings.maxWidth) -eq 24 ]]'
omarchy bar set "$ID" maxWidth "$(jq -r '.maxWidth // 200' <<<"$ORIG_ENTRY")" --json >/dev/null
omarchy bar set "$ID" showTitle "$(jq -r '.showTitle // true' <<<"$ORIG_ENTRY")" --json >/dev/null
omarchy bar set "$ID" highlightColor '#D97B3F' >/dev/null
check "a custom highlight colour reaches the taskbar" wait_for 5 '[[ $(here | jq -r .highlight) == "#d97b3f" ]]'
omarchy bar set "$ID" highlightColor '#abc' >/dev/null
check "…short hex is expanded" wait_for 5 '[[ $(here | jq -r .highlight) == "#aabbcc" ]]'
omarchy bar set "$ID" highlightColor 'not-a-colour' >/dev/null
check "…garbage falls back to the theme" wait_for 5 '[[ $(here | jq -r .highlight) == "" ]]'
omarchy bar set "$ID" highlightColor "$(jq -r '.highlightColor // ""' <<<"$ORIG_ENTRY")" >/dev/null
check "five suggested highlight colours, all valid hex" test "$(here | jq '[.highlightSuggestions[] | select(test("^#[0-9a-f]{6}$"))] | length')" -eq 5
check "the colour picker opens inside the settings popup" test "$(ipc colorPicker)|$(here | jq .pickerOpen)" = "settings|true"
ipc closePopups >/dev/null
check "…and resets when the popup closes" wait_for 3 '[[ $(here | jq .pickerOpen) == false ]]'
check "settings popup opens" test "$(ipc settings)" = settings
if command -v wtype >/dev/null; then
  sleep 0.8; wtype -k Escape
  check "Esc closes the settings" wait_for 3 '[[ $(here | jq -r .popup) == "" ]]'
  ipc colorPicker >/dev/null; sleep 0.8; wtype -k Escape
  check "with the colour picker open, Esc closes just the picker" wait_for 3 '[[ $(here | jq -r .popup) == settings && $(here | jq .pickerOpen) == false ]]'
  wtype -k Escape
  check "…and the next Esc the settings" wait_for 3 '[[ $(here | jq -r .popup) == "" ]]'
  ipc settings >/dev/null
else
  skip "Esc closes the settings" "wtype not installed"
fi
ipc closePopups >/dev/null
check "popups close" wait_for 3 '[[ $(here | jq -r .popup) == "" ]]'

section "hover highlight"
ipc hover "${P[0]}" >/dev/null
check "hover tags the window" wait_for 3 '[[ $(client "${P[0]}" | jq "[.tags[] | select(. == \"taskbox-hover\")] | length") -eq 1 ]]'
ipc hover "${P[1]}" >/dev/null
check "moving to another button moves the tag" wait_for 3 '[[ $(client "${P[0]}" | jq "[.tags[] | select(. == \"taskbox-hover\")] | length") -eq 0 && $(client "${P[1]}" | jq "[.tags[] | select(. == \"taskbox-hover\")] | length") -eq 1 ]]'
ipc hover "" >/dev/null
check "clearing removes it" wait_for 3 '[[ $(client "${P[1]}" | jq "[.tags[] | select(. == \"taskbox-hover\")] | length") -eq 0 ]]'

section "hover preview"
PREVIEWS=${XDG_RUNTIME_DIR:-/tmp}/taskbox-preview
pv() { here | jq -c .preview; }
pfile() { echo "$PREVIEWS/$(sed 's/^0x//' <<<"$1").png"; }
omarchy bar set "$ID" preview minimized >/dev/null
wait_for 5 '[[ $(pv | jq -r .mode) == minimized ]]'
C0=$(pv | jq .captures)   # the counter lives as long as the shell does
check "a minimized window gets a preview" test "$(ipc preview "${P[0]}")" = ok
check "…shown after the hover delay, with a picture" wait_for 3 '[[ $(pv | jq ".shown and .image and .last.ok") == true ]]'
check "…taken once, in well under a second ($(pv | jq .last.ms) ms)" test "$(pv | jq --argjson c "$C0" '.captures == $c + 1 and .last.ms < 1000')" = true
check "…at most 200 px wide and 120 px of picture" test "$(pv | jq '.size[0] >= 200 and .size[0] <= 240 and .size[1] <= 120 + 60')" = true
check "…stored privately in the runtime dir" test "$(stat -c %a "$(pfile "${P[0]}")" 2>&1)|$(stat -c %a "$PREVIEWS")" = "600|700"
PNG=$(file -b "$(pfile "${P[0]}")")
check "…as a small PNG ($(grep -oE '[0-9]+ x [0-9]+' <<<"$PNG"))" bash -c '[[ "$1" =~ ([0-9]+)\ x\ ([0-9]+) ]] && (( BASH_REMATCH[1] <= 2 * 200 + 1 && BASH_REMATCH[2] <= 2 * 120 + 1 ))' _ "$PNG"
ipc preview "" >/dev/null
check "hiding it" wait_for 2 '[[ $(pv | jq .shown) == false ]]'
ipc preview "${P[0]}" >/dev/null; sleep 0.8
check "hovering again within 3 s reuses the picture" test "$(pv | jq --argjson c "$C0" '.shown and .captures == $c + 1')" = true
ipc preview "${P[1]}" >/dev/null
check "moving to another minimized window switches at once" wait_for 2 '[[ $(pv | jq -r .target) == ${P[1]} && $(pv | jq ".shown and .image") == true ]]'
check "…capturing that one" test "$(pv | jq .captures)" -eq $((C0 + 2))
# A window with no picture yet: the card must not show, vanish and come back
# while the picture loads and the popup window first appears.
spawn_probes 1
F=$(comm -13 <(printf '%s\n' "${P[@]}" | sort) <(probes | sort) | head -1)
park "$F"
wait_for 5 '[[ $(here | jq --arg a "$F" "any(.windows[]; .address == \$a)") == true ]]'
sleep 1.2   # past the settle delay after the move
ipc preview "$F" >/dev/null
SAMPLES=""
for _ in $(seq 1 20); do SAMPLES+=$(pv | jq -r 'if .shown then "1" else "0" end'); sleep 0.1; done
check "once up, a card stays up while its first picture loads (no flicker)" bash -c '[[ $1 =~ ^0*1+$ ]]' _ "$SAMPLES"
ipc preview "" >/dev/null
lua "hl.dsp.window.close({ window = \"address:$F\" })"
sleep 3.2   # (the card on P1 refreshes once meanwhile)
N=$(pv | jq .captures); ipc preview "${P[0]}" >/dev/null
check "after 3 s the next hover takes a fresh one" wait_for 3 '[[ $(pv | jq ".shown and .captures == $((N + 1))") == true ]]'
N=$(pv | jq .captures)
check "while it stays up, it refreshes every 3 s" wait_for 5 '[[ $(pv | jq .captures) -eq $((N + 1)) ]]'
check "…not sooner" test "$(pv | jq '.last.ageMs')" -lt 3000
ipc menu "${P[0]}" >/dev/null
check "a menu opening hides it" wait_for 2 '[[ $(pv | jq .shown) == false ]]'
ipc closePopups >/dev/null
ACTIVE=$(here | jq -r '[.windows[] | select(.minimized | not)][0].address // empty')
if [[ -n $ACTIVE ]]; then
  check "a window that isn't minimized gets no preview" test "$(ipc preview "$ACTIVE")" = "no preview for this window"
else
  skip "a window that isn't minimized gets no preview" "no regular window on this workspace"
fi
ipc previewFailure true >/dev/null
ipc preview "${P[2]}" >/dev/null   # never captured before
check "a failed capture still shows the card (with the app icon)" wait_for 3 '[[ $(pv | jq ".shown and (.image | not) and .last.ok == false") == true ]]'
sleep 3.2; ipc preview "${P[0]}" >/dev/null   # has a picture from earlier
check "a failed refresh keeps the last good picture" wait_for 3 '[[ $(pv | jq ".shown and .image and .last.ok == false") == true ]]'
ipc previewFailure false >/dev/null
ipc preview "" >/dev/null
omarchy bar set "$ID" preview off >/dev/null
check "preview off: none" wait_for 5 '[[ $(ipc preview "${P[0]}") == "no preview for this window" ]]'
omarchy bar set "$ID" preview all >/dev/null
check "preview all: minimized windows still get one" wait_for 5 '[[ $(ipc preview "${P[1]}") == ok ]]'
ipc preview "" >/dev/null
omarchy bar set "$ID" preview minimized >/dev/null
spawn_probes 1
C=$(comm -13 <(printf '%s\n' "${P[@]}" | sort) <(probes | sort) | head -1)
park "$C"
wait_for 5 '[[ $(here | jq --arg a "$C" "any(.windows[]; .address == \$a)") == true ]]'
ipc preview "$C" >/dev/null
wait_for 3 '[[ $(pv | jq ".shown and .image") == true ]]'
lua "hl.dsp.window.close({ window = \"address:$C\" })"
check "its window closing hides the preview" wait_for 5 '[[ $(pv | jq .shown) == false ]]'
check "…and deletes its picture" wait_for 3 '[[ ! -e $(pfile "$C") ]]'

section "Alt lifts the drag guard (Alt+drag moves the taskbar)"
ipc hover "${P[1]}" >/dev/null
check "hovering a button blocks the bar's reorder drag" wait_for 3 '[[ $(here | jq .reorderGuard) == true && $(here | jq .reorderAreaEnabled) == false ]]'
lua 'hl.dsp.event("taskbox-alt>>1")'
check "holding Alt hands the press back to the bar" wait_for 3 '[[ $(here | jq .reorderGuard) == false && $(here | jq .reorderAreaEnabled) == true ]]'
lua 'hl.dsp.event("taskbox-alt>>0")'
check "releasing Alt blocks it again" wait_for 3 '[[ $(here | jq .reorderGuard) == true && $(here | jq .reorderAreaEnabled) == false ]]'
ipc hover "" >/dev/null
check "leaving the buttons restores the bar's own drag" wait_for 3 '[[ $(here | jq .reorderGuard) == false && $(here | jq .reorderAreaEnabled) == true ]]'

section "window menu"
check "menu opens for a window" test "$(ipc menu "${P[2]}")" = ok
check "menu is open" test "$(here | jq -r .popup)" = menu
act close "${P[2]}"
check "menu closes itself when its window closes" wait_for 5 '[[ $(here | jq -r .popup) == "" ]]'
check "closed window leaves the taskbar" wait_for 5 '[[ $(here | jq --arg a "${P[2]}" "[.windows[] | select(.address == \$a)] | length") -eq 0 ]]'

section "drag targets"
T=$(ipc dropTargets | jq --arg s "$(jq -r .screen <<<"$(here)")" '.[$s]')
check "workspace numbers are drop targets" test "$(jq length <<<"$T")" -ge 1
check "…in ascending order, left to right" test "$(jq '[.[].id | tonumber] == ([.[].id | tonumber] | sort) and ([.[].at] == ([.[].at] | sort))' <<<"$T")" = true

section "window actions (on a probe)"
A=${P[0]}
act toggle_floating "$A"
check "float toggles" wait_for 3 '[[ $(client "$A" | jq .floating) == true ]]'
act toggle_floating "$A"
act toggle_maximized "$A"
check "maximize toggles" wait_for 3 '[[ $(client "$A" | jq .fullscreen) -eq 1 ]]'
act toggle_maximized "$A"
check "…and restores" wait_for 3 '[[ $(client "$A" | jq .fullscreen) -eq 0 ]]'
lua "hl.dsp.window.move({ workspace = \"9\", follow = false, window = \"address:$A\" })"
act minimize "$A" minimized
check "minimizing tags the origin workspace" wait_for 3 '[[ $(client "$A" | jq "[.tags[] | select(. == \"taskbox-from-9\")] | length") -eq 1 ]]'
check "…so it's not on this workspace's taskbar" wait_for 3 '[[ $(here | jq --arg a "$A" "[.windows[] | select(.address == \$a)] | length") -eq 0 ]]'
act send "$A" special:taskboxprobe
check "moving between special workspaces keeps the origin" wait_for 3 '[[ $(client "$A" | jq -r .workspace.name) == special:taskboxprobe && $(client "$A" | jq "[.tags[] | select(. == \"taskbox-from-9\")] | length") -eq 1 ]]'
act send "$A" 9
check "send to a regular workspace clears it" wait_for 3 '[[ $(client "$A" | jq -r .workspace.name) == 9 && $(client "$A" | jq "[.tags[] | select(startswith(\"taskbox-from\"))] | length") -eq 0 ]]'
PID=$(client "$A" | jq .pid)
act kill "$A"
check "force kill ends the process" wait_for 5 '! kill -0 '"$PID"' 2>/dev/null'
check "missing windows are refused, nothing else touched" bash -c '
  before=$(hyprctl activewindow -j | jq -r .address)
  hyprctl dispatch "Taskbox.toggle_floating(\"0xdeadbeef\")" >/dev/null
  [[ $(hyprctl activewindow -j | jq -r .address) == "$before" ]]'

section "web app icons"
if command -v chromium >/dev/null; then
  cat >"$HOME/.local/share/applications/taskbox-test-webapp.desktop" <<EOF2
[Desktop Entry]
Type=Application
Name=Taskbox test web app
Exec=omarchy-launch-webapp https://example.com/
Icon=utilities-terminal
EOF2
  # (NoDisplay=true would hide it from Quickshell's app list, like the launcher.)
  sleep 2   # desktop entry scan
  launch_hidden special:minimized "chromium --app=https://example.com/ --user-data-dir=$TMP/chrome --no-first-run"
  if wait_for 20 '[[ -n $(hyprctl clients -j | jq -r ".[] | select(.class | startswith(\"chrome-example.com\")) | .address") ]]'; then
    WA=$(hyprctl clients -j | jq -r '.[] | select(.class | startswith("chrome-example.com")) | .address' | head -1)
    check "Chromium names the app window chrome-<host>__…" test -n "$(client "$WA" | jq -r '.class | select(test("^chrome-example\\.com__"))')"
    check "its icon comes from the web app's desktop entry" wait_for 5 '[[ $(here | jq -r --arg a "$WA" ".windows[] | select(.address == \$a) | .icon") == *utilities-terminal* ]]'
    lua "hl.dsp.window.close({ window = \"address:$WA\" })"
  else
    bad "web app window appeared" "no chrome-example.com window within 20s"
  fi
  pkill -f -- "--user-data-dir=$TMP/chrome"
else
  skip "web app icons" "chromium not installed"
fi

close_probes
check "all probes gone from the taskbar" wait_for 5 '[[ $(here | jq ".windows | length") -eq $BASE ]]'

if ((FULL)); then
  section "stress (--full): 20 windows at once"
  spawn_probes 20
  mapfile -t P < <(probes)
  for a in "${P[@]}"; do park "$a"; done
  check "all 20 are listed" wait_for 10 '[[ $(here | jq ".windows | length") -eq $((BASE + 20)) ]]'
  S=$(here)
  check "they overflow into +N" test "$(jq .overflowing <<<"$S")" = true
  check "shown buttons still fit" test "$(jq '(.fitCount * .buttonExtent + (.fitCount - 1) * 4 + 30 + 4) <= .available' <<<"$S")" = true
  START=$(date +%s%N); state >/dev/null; MS=$(( ($(date +%s%N) - START) / 1000000 ))
  check "state stays quick with 20 windows (${MS} ms)" test "$MS" -lt 1500
  close_probes
  check "…and all go away again" wait_for 10 '[[ $(here | jq ".windows | length") -eq $BASE ]]'

  section "vertical bar (--full)"
  spawn_probes 2
  for a in $(probes); do park "$a"; done
  omarchy bar position left >/dev/null
  check "left bar: vertical layout" wait_for 8 '[[ $(here | jq .vertical) == true ]]'
  S=$(here)
  check "…square icon buttons" test "$(jq '.buttonExtent == .barSize' <<<"$S")" = true
  check "…all windows listed" test "$(jq '.windows | length' <<<"$S")" -eq $((BASE + 2))
  VP=$(probes | head -1)
  ipc preview "$VP" >/dev/null
  check "…hover previews still open (beside the bar)" wait_for 3 '[[ $(here | jq ".preview.shown and .preview.image") == true ]]'
  # TASKBOX_SHOTS=<dir>: keep a picture of the bar's left edge with the preview.
  [[ -n ${TASKBOX_SHOTS:-} ]] && grim -g "0,0 480x360" "$TASKBOX_SHOTS/vertical-preview.png"
  ipc preview "" >/dev/null
  check "…drop targets still found" test "$(ipc dropTargets | jq length)" -ge 1
  omarchy bar position "$ORIG_POS" >/dev/null
  check "back to the $ORIG_POS bar" wait_for 8 '[[ $(here | jq .vertical) == false ]]'
  close_probes

  section "recovery (--full)"
  hyprctl reload >/dev/null
  check "Hyprland reload: re-attaches" wait_for 10 '[[ $(here | jq .integrated) == true ]]'
  check "…with exactly 4 Alt binds" wait_for 5 '[[ $(hyprctl binds -j | jq "[.[] | select(.key | test(\"^Alt_[LR]$\"))] | length") -eq 4 ]]'

  SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
  sleep 1   # let the reload above finish, so its own event isn't counted below
  timeout 12 socat -u UNIX-CONNECT:"$SOCK" - >"$TMP/events" 2>/dev/null &
  omarchy restart shell >/dev/null 2>&1
  check "shell restart: comes back" wait_for 10 'state >/dev/null 2>&1 && [[ $(here | jq .integrated) == true ]]'
  wait
  check "…without reloading Hyprland" test "$(grep -c configreloaded "$TMP/events")" -eq 0
  check "…one shell process" test "$(pgrep -xc quickshell)" -eq 1

  omarchy plugin disable "$ID" >/dev/null
  check "disabling: Hyprland drops the binds" wait_for 8 '[[ $(hyprctl binds -j | jq "[.[] | select(.key | test(\"^Alt_[LR]$\"))] | length") -eq 0 ]]'
  omarchy plugin enable "$ID" >/dev/null
  omarchy bar move "$ID" --section right --index 0 >/dev/null
  check "re-enabling: back with its binds" wait_for 10 '[[ $(hyprctl binds -j | jq "[.[] | select(.key | test(\"^Alt_[LR]$\"))] | length") -eq 4 ]]'
fi

section "shell log"
ERRORS=$(journalctl --user --since "$START_TIME" 2>/dev/null \
  | grep -E "mourningazazel\.taskbox/[^ ]*\.qml(:|\[)[0-9]+|[Bb]inding loop|TypeError|ReferenceError|another handler is registered for target mourningazazel" \
  | grep -v "Local plugin" || true)
if [[ -z $ERRORS ]]; then ok "no QML errors, warnings or binding loops logged during the run"
else bad "no QML errors, warnings or binding loops logged during the run" "$(head -5 <<<"$ERRORS")"; fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
((fail == 0))
