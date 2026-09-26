#!/bin/bash
# Development helpers for Taskbox. Safe by design: nothing here removes
# Hyprland binds/rules (that can crash Hyprland 0.56, see AGENTS.md), and the
# window-action tests run on throwaway "probe" windows parked on a hidden
# special workspace, never on real windows.
#
#   tools/dev.sh test              offline tests: consistency, facade API, unit (node), Lua, qmllint
#   tools/dev.sh test live [--full] [--facade]
#                                  live integration tests (see tests/live/run.sh)
#   tools/dev.sh test multimonitor [--facade]
#                                  on a virtual (headless) second monitor
#   tools/dev.sh ipc <fn> [arg]    call the widget's IPC API (state, check, icon, …)
#   tools/dev.sh reload            restart the Omarchy shell (QML is cached by path)
#   tools/dev.sh logs [-f]         shell log lines about Taskbox / QML errors
#   tools/dev.sh validate          omarchy plugin validate on this folder
#   tools/dev.sh state             integration status: Lua loaded, binds, bar entry
#   tools/dev.sh lua '<expr>'      dispatch a Lua expression, print taskbox>> replies
#   tools/dev.sh events [secs]     watch Taskbox events on Hyprland's socket
#   tools/dev.sh probe spawn|list|clean
#                                  throwaway windows for testing Taskbox.* actions
#
# Example action test:
#   tools/dev.sh probe spawn
#   tools/dev.sh lua "Taskbox.toggle_floating(\"$(tools/dev.sh probe list | head -1)\")"
#   tools/dev.sh probe clean

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ID=$(jq -r .id "$HERE/manifest.json")
SOCKET2="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
PROBE_CLASS="taskbox-probe"
PROBE_WORKSPACE="special:taskboxprobe"

need_hyprland() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -S $SOCKET2 ]] || { echo "Hyprland isn't reachable from this shell" >&2; exit 1; }
}

# Run a command while capturing Hyprland events; print the taskbox>> ones.
with_events() {
  local seconds=$1; shift
  local out; out=$(mktemp)
  timeout "$seconds" socat -u UNIX-CONNECT:"$SOCKET2" - >"$out" 2>/dev/null &
  local watcher=$!
  sleep 0.2
  "$@" >/dev/null
  wait "$watcher" 2>/dev/null || true
  grep -oE 'taskbox(-alt)?>>[^[:space:]]*' "$out" || echo "(no taskbox replies)"
  rm -f "$out"
}

probe_addresses() {
  hyprctl clients -j | jq -r --arg c "$PROBE_CLASS" '.[] | select(.class == $c) | .address'
}

case "${1:-}" in
  test)
    if [[ ${2:-} == live ]]; then
      exec "$HERE/tests/live/run.sh" "${@:3}"
    fi
    if [[ ${2:-} == multimonitor ]]; then
      exec "$HERE/tests/live/multimonitor.sh" "${@:3}"
    fi
    status=0
    echo "== consistency";  "$HERE/tests/manifest.sh" || status=1
    echo "== plugin facade"; "$HERE/tests/api/facade.sh" || status=1
    echo "== unit (node)";  (cd "$HERE" && node --test "tests/unit/*.test.mjs") || status=1
    echo "== lua";          (cd "$HERE" && "${LUA:-lua}" tests/lua/taskbox_spec.lua) || status=1
    echo "== qmllint";      "$HERE/tests/qml/lint.sh" || status=1
    ((status == 0)) && echo "all offline tests passed" || echo "SOME TESTS FAILED"
    exit $status
    ;;
  ipc)
    shift
    omarchy-shell "$ID" "$@"
    ;;
  reload)
    omarchy restart shell
    ;;
  logs)
    if [[ ${2:-} == -f ]]; then
      journalctl --user -f | grep --line-buffered -E "taskbox|Taskbox|TaskButton|TaskMenu|SettingsPopup|\.qml:[0-9]+|TypeError|ReferenceError|binding loop"
    else
      journalctl --user -b --since "-10min" | grep -E "taskbox|Taskbox|TaskButton|TaskMenu|SettingsPopup|\.qml:[0-9]+|TypeError|ReferenceError|binding loop" | grep -v "Local plugin changed" | tail -40
    fi
    ;;
  validate)
    omarchy plugin validate "$HERE" && echo "valid: $HERE"
    ;;
  state)
    need_hyprland
    echo "plugin:     $ID ($(jq -r .version "$HERE/manifest.json"))"
    echo "bar entry:  $(jq -c --arg id "$ID" '[.bar.layout[]?[]? | select(.id == $id)][0] // "not on the bar"' ~/.config/omarchy/shell.json)"
    echo "shells:     $(pgrep -xc quickshell || echo 0) quickshell process(es) (expect 1)"
    echo "alt binds:  $(hyprctl binds -j | jq '[.[] | select(.key | test("^Alt_"))] | length') (expect 4 from Taskbox, plus any of your own)"
    echo -n "lua side:   "
    with_events 1 hyprctl dispatch 'hl.dsp.event("taskbox>>state," .. tostring(_G.Taskbox ~= nil) .. "," .. tostring(_G.Taskbox and _G.Taskbox.installed) .. "," .. tostring(_G.Taskbox and _G.Taskbox.version))'
    echo "            (format: taskbox>>state,<loaded>,<installed>,<version>)"
    ;;
  lua)
    need_hyprland
    [[ -n ${2:-} ]] || { echo "usage: tools/dev.sh lua '<lua expression returning a dispatcher>'" >&2; exit 1; }
    with_events 1.5 hyprctl dispatch "$2"
    ;;
  events)
    need_hyprland
    timeout "${2:-30}" socat -u UNIX-CONNECT:"$SOCKET2" - | grep --line-buffered -E "taskbox|configreloaded" || true
    ;;
  probe)
    need_hyprland
    case "${2:-}" in
      spawn)
        # Placement rides on the launch itself, so the window maps straight
        # onto the hidden workspace (never on screen, never focused).
        hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a $PROBE_CLASS sleep 900\", { workspace = \"$PROBE_WORKSPACE silent\" })" >/dev/null
        sleep 1.5
        probe_addresses
        ;;
      list)
        probe_addresses
        ;;
      clean)
        for address in $(probe_addresses); do
          hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null
        done
        sleep 0.5
        echo "probe windows left: $(probe_addresses | wc -l | tr -d ' ')"
        ;;
      *) echo "usage: tools/dev.sh probe spawn|list|clean" >&2; exit 1 ;;
    esac
    ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    [[ -z ${1:-} ]] || exit 1
    ;;
esac
