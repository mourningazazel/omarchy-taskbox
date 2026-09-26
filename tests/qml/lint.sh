#!/bin/bash
# Static checks for the QML files with qmllint, against the installed Omarchy
# shell (for the qs.* imports) and Quickshell. Style-only categories are off —
# the shell's own code is dynamically typed (untyped `bar`, `taskbar`, …), so
# those would be noise. What stays on catches real breakage: syntax, imports,
# unresolved/missing types, duplicate bindings/names, required properties,
# read-only writes, unused imports, unreachable code.
#
# Usage: tests/qml/lint.sh            (exit 1 on any finding)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHELL_DIR=${OMARCHY_PATH:-/usr/share/omarchy}/shell
QMLLINT=$(command -v qmllint6 || command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
[[ -x $QMLLINT ]] || { echo "qmllint not found (qt6-declarative)"; exit 2; }
[[ -d $SHELL_DIR ]] || { echo "Omarchy shell not found at $SHELL_DIR"; exit 2; }

# The shell's modules are imported as qs.<Dir>; expose the shell dir as `qs`.
IMPORTS=$(mktemp -d)
trap 'rm -rf "$IMPORTS"' EXIT
ln -s "$SHELL_DIR" "$IMPORTS/qs"

QUIET=(unqualified missing-property incompatible-type prefer-non-var-properties
  stale-property-read access-singleton-via-object equality-type-coercion
  context-properties uncreatable-type deprecated)
ARGS=()
for category in "${QUIET[@]}"; do ARGS+=("--$category" disable); done

cd "$ROOT"
out=$("$QMLLINT" "${ARGS[@]}" -I "$IMPORTS" -I /usr/lib/qt6/qml ./*.qml 2>&1 || true)
findings=$(grep -E "^(Warning|Error):" <<<"$out" || true)
if [[ -n $findings ]]; then
  echo "$out"
  echo "qmllint: $(wc -l <<<"$findings") finding(s)"
  exit 1
fi
echo "qmllint: clean ($(ls ./*.qml | wc -l) files)"
