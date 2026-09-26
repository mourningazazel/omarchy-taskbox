#!/bin/bash
# From Omarchy 4.0.4, third-party bar widgets get a restricted facade
# (shell/Ui/PluginBarApi.qml) as `bar`, not the host Bar. This checks that
# Taskbox only uses members that facade has:
#   * every `bar.X` / `host.X` / `taskbar.host.X` in the QML is a member of
#     BarFacade.qml (our exact stand-in for PluginBarApi)
#   * when the installed Omarchy ships PluginBarApi.qml, BarFacade.qml exposes
#     exactly the same public members (so the stand-in can't drift)
set -uo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
fail=0

members() {  # public properties + functions of a QtObject file
  grep -oE '^\s+(readonly )?property [a-z]+ [A-Za-z_]+|^\s+function [A-Za-z_]+' "$1" \
    | awk '{print $NF}' | grep -v '^_' | grep -vx 'real' | sort -u
}

FACADE=$(members BarFacade.qml)

# Member accesses on the bar handle, ignoring comments and Style.bar.*
USED=$(sed -E 's#//.*$##' ./*.qml \
  | grep -oE '(\b(taskbar\.)?host|(^|[^A-Za-z_.])bar)\.[A-Za-z_]+' \
  | grep -vE 'Style\.bar' | sed -E 's/.*\.//' | sort -u)

for m in $USED; do
  if grep -qx "$m" <<<"$FACADE"; then echo "  ✓ bar.$m"; else echo "  ✗ bar.$m is not in Omarchy's plugin facade"; fail=1; fi
done

REAL=${OMARCHY_PATH:-/usr/share/omarchy}/shell/Ui/PluginBarApi.qml
if [[ -f $REAL ]]; then
  if diff <(members "$REAL") <(echo "$FACADE") >/dev/null; then
    echo "  ✓ BarFacade.qml matches the installed PluginBarApi.qml"
  else
    echo "  ✗ BarFacade.qml differs from the installed PluginBarApi.qml:"
    diff <(members "$REAL") <(echo "$FACADE") | sed 's/^/      /'
    fail=1
  fi
else
  echo "  - installed Omarchy predates the plugin facade (no PluginBarApi.qml); stand-in not compared"
fi
exit $fail
