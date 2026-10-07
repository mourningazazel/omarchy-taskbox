#!/bin/bash
# Exercise actual taskbar clicks on overlapping floating probe windows on a
# temporary headless monitor. Run with the candidate Lua module loaded.
set -euo pipefail

ID=mourningazazel.taskbox
# Screens and similar display managers recognize HEADLESS-* as test outputs.
OUT=HEADLESS-TASKBOX-FLOATING
PROBE=taskbox-floating-probe
TMP=$(mktemp -d)
hyprctl activewindow -j > "$TMP/active.json"
hyprctl cursorpos -j > "$TMP/cursor.json"
START_WS=$(hyprctl activeworkspace -j | jq -r .id)
START_WORKSPACES=$(hyprctl monitors -j | jq -c '[.[].activeWorkspace.id]')
created=0
passed=0
failed=0

lua() { hyprctl dispatch "$1" >/dev/null; }
ipc() { omarchy-shell "$ID" "$@"; }
probes() { hyprctl clients -j | jq -r --arg c "$PROBE" '.[] | select(.class == $c) | .address'; }
client() { hyprctl clients -j | jq -c --arg a "$1" '.[] | select(.address == $a)'; }
top_probe() { hyprctl clients -j | jq -r --arg c "$PROBE" '[.[] | select(.class == $c)][-1].address'; }
active() { hyprctl activewindow -j | jq -r .address; }
button_active() { ipc state | jq -r --arg a "$1" '[.[].windows[] | select(.address == $a)][0].active'; }
button_minimized() { ipc state | jq -r --arg a "$1" '[.[].windows[] | select(.address == $a)][0].minimized'; }
wait_for() {
  local deadline=$((SECONDS + 5))
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep 0.1
  done
}
equals() { [[ $("$2" "${@:3}") == "$1" ]]; }
check() {
  local name=$1; shift
  if wait_for "$@"; then
    printf 'PASS %s\n' "$name"; passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$name"; failed=$((failed + 1))
  fi
}
workspace() { client "$1" | jq -r .workspace.name; }

cleanup() {
  for a in $(probes); do
    lua "hl.dsp.window.close({ window = \"address:$a\" })" || true
  done
  if ((created)); then hyprctl output remove "$OUT" >/dev/null || true; fi
  # Restore focus without moving the pointer or changing the user's config.
  local original
  original=$(jq -r '.address // empty' "$TMP/active.json")
  lua "(function() local p = hl.get_config(\"cursor.no_warps\"); hl.config({cursor = {no_warps = true}}); local w = hl.get_window(\"address:$original\"); if w then hl.dispatch(hl.dsp.focus({window = \"address:$original\"})) else hl.dispatch(hl.dsp.focus({workspace = \"$START_WS\"})) end; hl.config({cursor = {no_warps = p}}); return hl.dsp.event(\"taskbox>>floating-test-cleanup\") end)()" || true
  rm -rf "$TMP"
}

[[ -z $(probes) ]] || { echo "Existing floating probes; refusing to reuse them"; exit 2; }
hyprctl monitors -j | jq -e --arg m "$OUT" 'all(.[]; .name != $m)' >/dev/null
trap cleanup EXIT
hyprctl output create headless "$OUT" >/dev/null
created=1
monitor_ready() {
  hyprctl monitors -j | jq -e --arg m "$OUT" --argjson old "$START_WORKSPACES" \
    '.[] | select(.name == $m) | .activeWorkspace.id as $id | $id > 0 and ($old | index($id)) == null' >/dev/null
}
wait_for monitor_ready
WS=$(hyprctl monitors -j | jq -r --arg m "$OUT" '.[] | select(.name == $m) | .activeWorkspace.id')
for i in 1 2; do
  lua "hl.dsp.exec_cmd(\"foot -a $PROBE sleep 120\", {workspace = \"special:taskbox-floating-test silent\"})"
done
two_probes() { [[ $(probes | wc -l) == 2 ]]; }
wait_for two_probes
mapfile -t P < <(probes)
A=${P[0]}; B=${P[1]}
for a in "$A" "$B"; do
  lua "hl.dsp.window.float({action = \"enable\", window = \"address:$a\"})"
  lua "hl.dsp.window.move({workspace = \"$WS\", follow = false, window = \"address:$a\"})"
  lua "hl.dsp.window.move({x = 100, y = 100, relative = false, window = \"address:$a\"})"
done
listed() { ipc state | jq -e --arg a "$A" --arg b "$B" '[.[].windows[].address] | index($a) != null and index($b) != null' >/dev/null; }
wait_for listed
on_test_monitor() { client "$1" | jq -e --argjson ws "$WS" '.workspace.id == $ws' >/dev/null; }
wait_for on_test_monitor "$A"
wait_for on_test_monitor "$B"

# clients JSON follows Hyprland's bottom-to-top window list (0.56).
lua "hl.dsp.window.alter_zorder({mode = \"top\", window = \"address:$B\"})"
lua "(function() local p = hl.get_config(\"cursor.no_warps\"); hl.config({cursor = {no_warps = true}}); hl.dispatch(hl.dsp.focus({window = \"address:$B\"})); hl.config({cursor = {no_warps = p}}); return hl.dsp.event(\"taskbox>>floating-test-ready\") end)()"
wait_for equals "$B" active
wait_for equals true button_active "$B"
hyprctl cursorpos -j > "$TMP/cursor.json"
ipc click "$A" >/dev/null
check "click focuses the obscured floating window" equals "$A" active
check "click brings it above the other floating window" equals "$A" top_probe
check "its taskbar button becomes active" equals true button_active "$A"

# The normal preference remains enabled: an active button minimizes.
ipc click "$A" >/dev/null
check "clicking the active tab still minimizes" equals special:minimized workspace "$A"
check "its taskbar button becomes minimized" equals true button_minimized "$A"
lua "hl.dsp.window.alter_zorder({mode = \"top\", window = \"address:$B\"})"
ipc click "$A" >/dev/null
check "clicking the minimized tab restores its workspace" equals "$WS" workspace "$A"
check "restoring brings it to the front" equals "$A" top_probe
check "restoring gives it keyboard focus" equals "$A" active
check "cursor stays in place" equals "$(jq -c . "$TMP/cursor.json")" bash -c 'hyprctl cursorpos -j | jq -c .'

printf '%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
