#!/bin/bash
# Multi-monitor integration tests, on a real second monitor that nobody sees:
# Hyprland's headless output (`hyprctl output create headless`). To Hyprland,
# Quickshell and Omarchy it's an ordinary monitor — it gets its own bar, its
# own Taskbox instance and its own workspace — so test windows can live on it
# without touching the real screen. The output is removed again on exit.
#
#   tests/live/multimonitor.sh            (add --facade for the 4.0.4 plugin API)
#
# Run it while you're not using the desktop: switching workspaces during the
# run can fail the "main monitor unchanged" checks, and the virtual monitor
# sits to the right of the real one, so keep the mouse off that edge.
#
# Safety: windows are throwaway "probes" launched straight onto the virtual
# monitor's workspace. The one step that moves keyboard focus there hands it
# straight back. Settings, focus, workspace and cursor are restored on exit.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ID=$(jq -r .id "$ROOT/manifest.json")
OUT=TASKBOX-MM
PROBE=taskbox-probe
SHELL_JSON=$HOME/.config/omarchy/shell.json
FACADE=0; [[ ${1:-} == --facade ]] && FACADE=1

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \e[31m✗ %s\e[0m\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
section() { printf '\n%s\n' "$1"; }
check() { local name=$1; shift; local out; if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$out"; fi; }
wait_for() { local deadline=$((SECONDS + $1)); shift; until eval "$@"; do ((SECONDS >= deadline)) && return 1; sleep 0.2; done; }

ipc()    { omarchy-shell "$ID" "$@"; }
state()  { ipc state; }
on()     { state | jq --arg s "$1" '[.[] | select(.screen == $s)][0]'; }   # snapshot for a monitor
lists()  { on "$1" | jq -e --arg a "$2" 'any(.windows[]; .address == $a)' >/dev/null; }
lua()    { hyprctl dispatch "$1" >/dev/null; }
client() { hyprctl clients -j | jq -c --arg a "$1" '.[] | select(.address == $a)'; }
probes() { hyprctl clients -j | jq -r --arg c "$PROBE" '.[] | select(.class == $c) | .address'; }
monitor_ws() { hyprctl monitors -j | jq -r --arg m "$1" '.[] | select(.name == $m) | .activeWorkspace.id'; }
probe_only() { [[ $(client "$1" | jq -r .class) == "$PROBE" ]] || { echo "refusing: $1 isn't a probe"; exit 99; }; }
act() { local fn=$1 a=$2; shift 2; probe_only "$a"; local args="\"$a\""; for x in "$@"; do args+=", \"$x\""; done; lua "Taskbox.$fn($args)"; }
tags() { client "$1" | jq -c '[.tags[] | select(startswith("taskbox"))]'; }
# A warp would put the cursor on the virtual monitor. (Keep the mouse off the
# right edge of the screen during the run: the virtual monitor is there.)
cursor_home() {
  local x y; IFS=', ' read -r x y <<<"$(hyprctl cursorpos)"
  hyprctl monitors -j | jq -e --arg m "$OUT" --argjson x "$x" --argjson y "$y" \
    '.[] | select(.name == $m) | ($x < .x or $x >= .x + .width / .scale or $y < .y or $y >= .y + .height / .scale)' >/dev/null
}
# Focus a workspace without warping the cursor (like Taskbox's own actions).
focus_ws() {
  lua "(function() local p = hl.get_config(\"cursor.no_warps\"); hl.config({ cursor = { no_warps = true } }); hl.dispatch(hl.dsp.focus({ workspace = \"$1\" })); hl.config({ cursor = { no_warps = p } }); return hl.dsp.event(\"taskbox>>test\") end)()"
}

MAIN=$(hyprctl monitors -j | jq -r '[.[] | select(.name != "'"$OUT"'")][0].name')
START_WS=$(hyprctl activeworkspace -j | jq .id)
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
ORIG_ENTRY=$(jq -c --arg id "$ID" '[.bar.layout[]?[]? | select(.id == $id)][0] // empty' "$SHELL_JSON")
[[ -n $ORIG_ENTRY ]] || { echo "$ID is not on the bar"; exit 2; }
SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
EVENTS=$(mktemp)
timeout 600 socat -u UNIX-CONNECT:"$SOCK" - >"$EVENTS" 2>/dev/null &
WATCH=$!

cleanup() {
  ipc hover "" >/dev/null 2>&1; ipc preview "" >/dev/null 2>&1; ipc closePopups >/dev/null 2>&1
  for a in $(probes); do lua "hl.dsp.window.close({ window = \"address:$a\" })"; done
  hyprctl monitors -j | jq -e --arg m "$OUT" 'any(.[]; .name == $m)' >/dev/null && hyprctl output remove "$OUT" >/dev/null
  omarchy bar set "$ID" minWidth "$(jq -r '.minWidth // 44' <<<"$ORIG_ENTRY")" --json >/dev/null 2>&1
  omarchy bar set "$ID" emulateFacade "$(jq -r '.emulateFacade // false' <<<"$ORIG_ENTRY")" --json >/dev/null 2>&1
  omarchy bar set "$ID" preview "$(jq -r '.preview // "minimized"' <<<"$ORIG_ENTRY")" >/dev/null 2>&1
  focus_ws "$START_WS"
  kill "$WATCH" 2>/dev/null; rm -f "$EVENTS"
}
trap cleanup EXIT

if ((FACADE)); then omarchy bar set "$ID" emulateFacade true --json >/dev/null; sleep 2; fi

# ------------------------------------------------------------------ setup
section "a second monitor ($OUT, headless)"
hyprctl output remove "$OUT" >/dev/null 2>&1
# Placement stays "auto" (to the right of the real screen). Don't try to park
# it far away: the real screen's own `position = "auto"` rule then re-lays it
# out next to the virtual one, dragging the cursor and focus along.
hyprctl output create headless "$OUT" >/dev/null
check "virtual monitor created" wait_for 5 '[[ -n $(monitor_ws $OUT) ]]'
check "…without moving the real screen" test "$(hyprctl monitors -j | jq -c --arg m "$MAIN" '.[] | select(.name == $m) | [.x, .y]')" = "[0,0]"
WSB=$(monitor_ws "$OUT")
# (RHS quoted: unquoted, [[ == ]] treats the JSON's [ ] as a glob pattern)
check "one Taskbox per monitor" wait_for 10 '[[ $(state | jq -c "[.[].screen] | sort") == "$(jq -cn --arg a "$MAIN" --arg b "$OUT" "[\$a, \$b] | sort")" ]]'
check "both attached to Hyprland" wait_for 10 '[[ $(state | jq "all(.[]; .integrated)") == true ]]'
check "each follows its own monitor's workspace" test "$(on "$OUT" | jq .workspace)" = "$WSB"
check "…and the main one still its own" wait_for 3 '[[ $(on "$MAIN" | jq .workspace) == $(monitor_ws "$MAIN") ]]'
check "each found its own bar slot and sections" test "$(state | jq 'all(.[]; .slotFound and .barSlots >= 3)')" = true
check "exactly one instance serves IPC" test "$(state | jq '[.[] | select(.ipcPrimary)] | length')" -eq 1
check "running $( ((FACADE)) && echo 'behind the plugin facade' || echo 'with the host bar')" test "$(state | jq "all(.[]; .facade == $( ((FACADE)) && echo true || echo false))")" = true
check "focus stayed on the main monitor" test "$(hyprctl activeworkspace -j | jq .id)" = "$START_WS"
check "…and the cursor too" cursor_home

# ------------------------------------------------------------------ windows per monitor
section "windows belong to their monitor's taskbar"
for i in 1 2 3; do
  hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a $PROBE sleep 900\", { workspace = \"$WSB silent\" })" >/dev/null
  sleep 0.3
done
wait_for 10 '[[ $(probes | wc -l) -ge 3 ]]'
mapfile -t P < <(probes)
# (Hyprland may give the new monitor a workspace that isn't shown elsewhere
# — with your windows on it — so check for the probes, not an exact count.)
check "the virtual monitor's bar lists its 3 windows" wait_for 5 '[[ $(on "$OUT" | jq --argjson p "$(printf "%s\n" "${P[@]}" | jq -R . | jq -s .)" "[.windows[].address] | contains(\$p)") == true ]]'
check "the main bar lists none of them" test "$(on "$MAIN" | jq --argjson p "$(printf '%s\n' "${P[@]}" | jq -R . | jq -s .)" '[.windows[] | select(.address as $a | $p | index($a))] | length')" -eq 0
check "each bar sizes itself to its own width" test "$(state | jq 'all(.[]; .available <= .barLength)')" = true
S=$(on "$OUT")
check "…and the buttons fit ($(jq .fitCount <<<"$S") × $(jq .buttonExtent <<<"$S") px in $(jq .available <<<"$S"))" test "$(jq '(.fitCount * .buttonExtent) <= .available' <<<"$S")" = true
check "drop targets exist on both bars" test "$(ipc dropTargets | jq --arg a "$MAIN" --arg b "$OUT" '(.[$a] | length) > 0 and (.[$b] | length) > 0')" = true

section "focus across monitors"
act focus "${P[0]}"
check "clicking a window on the other monitor focuses it" wait_for 3 '[[ $(hyprctl activewindow -j | jq -r .address) == ${P[0]} ]]'
check "…its button shows as active there" wait_for 3 '[[ $(on "$OUT" | jq --arg a "${P[0]}" ".windows[] | select(.address == \$a) | .active") == true ]]'
check "…and the cursor isn't warped onto that monitor" cursor_home
focus_ws "$START_WS"   # hand focus straight back
check "focus handed back to the main monitor" wait_for 3 '[[ $(hyprctl activeworkspace -j | jq .id) == $START_WS ]]'
check "…still without warping the cursor" cursor_home

section "hover and menus are per monitor"
ipc hover "${P[1]}" >/dev/null
check "hovering tags the window on the other monitor" wait_for 3 '[[ $(tags "${P[1]}") == "[\"taskbox-hover\"]" ]]'
ipc hover "" >/dev/null
check "…and clears" wait_for 3 '[[ $(tags "${P[1]}") == "[]" ]]'
ipc menu "${P[1]}" >/dev/null
check "its menu opens on that monitor's bar only" wait_for 3 '[[ $(on "$OUT" | jq -r .popup) == menu && $(on "$MAIN" | jq -r .popup) == "" ]]'
ipc closePopups >/dev/null

section "hover previews are per monitor"
# "all": the probes here aren't minimized. (Captures only ever touch probes.)
omarchy bar set "$ID" preview all >/dev/null
wait_for 5 '[[ $(state | jq "all(.[]; .preview.mode == \"all\")") == true ]]'
# A probe with a button of its own there (not in +N).
PV=$(on "$OUT" | jq -r --argjson p "$(printf '%s\n' "${P[@]}" | jq -R . | jq -s .)" '[.windows[] | select(.shown and (.address as $a | $p | index($a)))][0].address')
check "a window on the other monitor gets a preview" test "$(ipc preview "$PV")" = ok
check "…on that monitor's bar only" wait_for 3 '[[ $(on "$OUT" | jq ".preview.shown and .preview.image") == true && $(on "$MAIN" | jq .preview.shown) == false ]]'
check "…sized for that monitor (dpr $(on "$OUT" | jq .preview.dpr))" test "$(on "$OUT" | jq '.preview.size[0] >= 200 and .preview.size[0] <= 240')" = true
ipc preview "" >/dev/null
check "…and hides" wait_for 2 '[[ $(on "$OUT" | jq .preview.shown) == false ]]'

section "minimize and restore stay on their monitor"
act minimize "${P[2]}" minimized
check "minimizing tags the other monitor's workspace ($WSB)" wait_for 3 '[[ $(tags "${P[2]}") == "[\"taskbox-from-$WSB\"]" ]]'
check "it stays on that monitor's taskbar, dimmed" wait_for 3 '[[ $(on "$OUT" | jq --arg a "${P[2]}" ".windows[] | select(.address == \$a) | .minimized") == true ]]'
check "…and doesn't appear on the main one" test "$(on "$MAIN" | jq --arg a "${P[2]}" '[.windows[] | select(.address == $a)] | length')" -eq 0
ipc click "${P[2]}" >/dev/null
check "clicking it restores it to ITS monitor's workspace" wait_for 3 '[[ $(client "${P[2]}" | jq .workspace.id) == $WSB ]]'
focus_ws "$START_WS"

# A window that was *born* minimized has no known monitor: like Windows'
# default "show buttons on all taskbars", it's listed on every bar.
hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a $PROBE sleep 900\", { workspace = \"special:minimized silent\" })" >/dev/null
wait_for 10 '[[ $(probes | wc -l) -ge 4 ]]'
U=$(comm -13 <(printf '%s\n' "${P[@]}" | sort) <(probes | sort) | head -1)
check "a window with no known monitor shows on every taskbar" wait_for 5 '[[ $(state | jq --arg a "$U" "all(.[]; any(.windows[]; .address == \$a))") == true ]]'

section "the other monitor changes on its own"
lua "hl.dsp.focus({ monitor = \"$OUT\" })"
focus_ws 8                     # a fresh workspace on the virtual monitor
# (the born-minimized window $U is listed everywhere, by design)
check "its taskbar follows its workspace switch" wait_for 3 '[[ $(on "$OUT" | jq .workspace) == 8 && $(on "$OUT" | jq -c "[.windows[].address]") == "[\"$U\"]" ]]'
check "…while the main taskbar doesn't change" test "$(on "$MAIN" | jq .workspace)" = "$START_WS"
omarchy-shell shell toggle "$ID" '{}' >/dev/null
check "Omarchy's settings summon opens on the focused monitor" wait_for 3 '[[ $(on "$OUT" | jq -r .popup) == settings && $(on "$MAIN" | jq -r .popup) == "" ]]'
ipc closePopups >/dev/null
check "IPC 'settings' also targets the focused monitor" test "$(ipc settings)|$(on "$MAIN" | jq -r .popup)" = "settings|"
ipc closePopups >/dev/null
focus_ws "$WSB"
check "…and back" wait_for 3 '[[ $(on "$OUT" | jq .workspace) == $WSB ]]'
focus_ws "$START_WS"
check "focus handed back to the main monitor" wait_for 3 '[[ $(hyprctl activeworkspace -j | jq .id) == $START_WS ]]'

section "a window moving to another monitor"
act send "${P[1]}" 9           # a workspace on the main monitor that isn't shown
check "it leaves this monitor's taskbar" wait_for 3 '! lists "$OUT" "${P[1]}"'
check "…and isn't on the main one (its workspace isn't the visible one)" test "$(on "$MAIN" | jq --arg a "${P[1]}" '[.windows[] | select(.address == $a)] | length')" -eq 0
act send "${P[1]}" "$WSB"
check "sending it back returns it" wait_for 3 'lists "$OUT" "${P[1]}"'

section "different and fractional scales"
SHOTS=${TASKBOX_SHOTS:-}
for sc in 1 1.25 1.5 2; do
  hyprctl eval "hl.monitor({ output = \"$OUT\", mode = \"1920x1080\", position = \"auto\", scale = $sc })" >/dev/null
  want=$(awk -v s="$sc" 'BEGIN { printf "%d", 1920 / s + 0.5 }')
  if wait_for 6 '[[ $(on "$OUT" | jq .barLength) -eq '"$want"' ]]'; then
    sleep 1.5   # a sizing tick
    S=$(on "$OUT")
    check "scale $sc: bar is $want px, buttons fit ($(jq .fitCount <<<"$S")×$(jq .buttonExtent <<<"$S") in $(jq .available <<<"$S"))" \
      test "$(jq --argjson p "$(printf '%s\n' "${P[@]}" | jq -R . | jq -s .)" '.available <= .barLength and (.fitCount * .buttonExtent) <= .available and ([.windows[].address] | contains($p))' <<<"$S")" = true
    # The preview picture is taken at this monitor's pixel density.
    ipc preview "" >/dev/null; sleep 3.1   # past the 3 s reuse window
    ipc preview "${P[0]}" >/dev/null
    if wait_for 3 '[[ $(on "$OUT" | jq ".preview.shown and .preview.image") == true ]]'; then
      dims=$(file -b "${XDG_RUNTIME_DIR:-/tmp}/taskbox-preview/${P[0]#0x}.png" | grep -oE '[0-9]+ x [0-9]+')
      check "scale $sc: preview picture $dims px fits a 200x120 box at ${sc}x" \
        awk -v d="$dims" -v s="$sc" 'BEGIN { split(d, a, " x "); w = a[1]; h = a[2]
          exit !(w <= 200 * s + 1 && h <= 120 * s + 1 && (w >= 200 * s - 3 || h >= 120 * s - 3)) }'
    else
      bad "scale $sc: preview shown" "$(on "$OUT" | jq -c .preview)"
    fi
    [[ -n $SHOTS ]] && grim -o "$OUT" "$SHOTS/scale-$sc.png"
    ipc preview "" >/dev/null
  else
    bad "scale $sc: bar resized to $want px" "barLength $(on "$OUT" | jq .barLength)"
  fi
done

section "overflow is per monitor"
omarchy bar set "$ID" minWidth 300 --json >/dev/null
check "the narrow virtual monitor overflows" wait_for 5 '[[ $(on "$OUT" | jq .overflowing) == true ]]'
check "…computed from its own space, not the main bar's" test "$(state | jq --arg b "$OUT" '[.[] | .available] | unique | length')" -eq 2
omarchy bar set "$ID" minWidth "$(jq -r '.minWidth // 44' <<<"$ORIG_ENTRY")" --json >/dev/null

section "unplugging and replugging"
ipc hover "${P[0]}" >/dev/null
ipc preview "${P[0]}" >/dev/null   # unplug with a preview open on it
wait_for 3 '[[ $(tags "${P[0]}") == "[\"taskbox-hover\"]" ]]'
hyprctl output remove "$OUT" >/dev/null
check "its Taskbox goes away with it" wait_for 8 '[[ $(state | jq length) -eq 1 ]]'
check "a hover highlight on it is cleared" wait_for 5 '[[ $(tags "${P[0]}") == "[]" ]]'
check "IPC still answers" test "$(state | jq '.[0].integrated')" = true
check "…from the remaining instance" test "$(state | jq '.[0].ipcPrimary')" = true
sleep 3   # the cleanup check runs 2 s after an instance goes away
check "no Hyprland reload (Taskbox is still enabled)" test "$(grep -c configreloaded "$EVENTS")" -eq 0
check "Alt binds intact" test "$(hyprctl binds -j | jq '[.[] | select(.key | test("^Alt_[LR]$"))] | length')" -eq 4
check "the main monitor's workspace is unchanged" test "$(monitor_ws "$MAIN")" = "$START_WS"
hyprctl output create headless "$OUT" >/dev/null
check "plugging it back brings a Taskbox back" wait_for 10 '[[ $(state | jq length) -eq 2 && $(state | jq "all(.[]; .integrated)") == true ]]'
check "still exactly one IPC server" test "$(state | jq '[.[] | select(.ipcPrimary)] | length')" -eq 1

section "shell log"
ERRORS=$(journalctl --user --since "$START_TIME" 2>/dev/null \
  | grep -E "mourningazazel\.taskbox/[^ ]*\.qml(:|\[)[0-9]+|[Bb]inding loop|TypeError|ReferenceError|another handler is registered for target mourningazazel" \
  | grep -v "Local plugin" || true)
[[ -z $ERRORS ]] && ok "no QML errors, warnings or binding loops" || bad "no QML errors, warnings or binding loops" "$(head -5 <<<"$ERRORS")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
