#!/bin/bash
# Project consistency checks that need no Omarchy install (CI-friendly):
#   * manifest rules mirroring `omarchy plugin validate`
#   * settings defaults agree across manifest defaults, manifest schema,
#     lib/Logic.js DEFAULTS and the README settings table
#   * the version agrees across manifest.json, hypr/taskbox.lua and CHANGELOG.md
set -uo pipefail
export LC_ALL=C   # identical sort order for every key list

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
M=manifest.json
fail=0
err() { echo "  ✗ $1"; fail=1; }
ok() { echo "  ✓ $1"; }

echo "manifest"
jq -e . "$M" >/dev/null 2>&1 || { echo "  ✗ manifest.json is not valid JSON"; exit 1; }
[[ $(jq .schemaVersion "$M") == 1 ]] && ok "schemaVersion 1" || err "schemaVersion must be 1"
for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' "$M" >/dev/null || err "missing required field '$field'"
done
ID=$(jq -r .id "$M")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $ID != *..* && $ID != omarchy.* ]] && ok "id '$ID'" || err "invalid id '$ID'"
jq -e '.kinds | type == "array" and length > 0' "$M" >/dev/null && ok "kinds" || err "kinds must be a non-empty array"
while read -r ep; do
  [[ $ep != /* && $ep != *..* && -f $ep ]] && ok "entry point $ep" || err "bad entry point '$ep'"
done < <(jq -r '.entryPoints[]' "$M")
section=$(jq -r '.barWidget.defaultSection // "right"' "$M")
[[ $section =~ ^(left|center|right)$ ]] && ok "defaultSection $section" || err "defaultSection '$section'"
links=$(find . -path ./.git -prune -o -type l -print)
[[ -z $links ]] && ok "no symlinks" || err "symlinks are not allowed: $links"

echo "settings"
manifest_keys=$(jq -r '.barWidget.defaults | keys[]' "$M" | sort | tr '\n' ' ')
schema_keys=$(jq -r '.barWidget.schema[].key' "$M" | sort | tr '\n' ' ')
logic=$(node -e '
  const vm = require("vm"), fs = require("fs")
  const ctx = vm.createContext({})
  vm.runInContext(fs.readFileSync("lib/Logic.js", "utf8").replace(/^\.pragma library\s*$/m, ""), ctx)
  process.stdout.write(JSON.stringify(ctx.DEFAULTS))')
logic_keys=$(jq -r 'keys[]' <<<"$logic" | sort | tr '\n' ' ')
readme_keys=$(grep -oE '^\| `[A-Za-z]+` \|' README.md | grep -oE '[A-Za-z]+' | sort | tr '\n' ' ')
[[ $manifest_keys == "$schema_keys" ]] && ok "schema covers every default" || err "defaults [$manifest_keys] vs schema [$schema_keys]"
[[ $manifest_keys == "$logic_keys" ]] && ok "Logic.js DEFAULTS match the manifest" || err "manifest [$manifest_keys] vs Logic.js [$logic_keys]"
[[ $manifest_keys == "$readme_keys" ]] && ok "README documents every setting" || err "manifest [$manifest_keys] vs README [$readme_keys]"
if [[ $(jq -S .barWidget.defaults "$M") == $(jq -S . <<<"$logic") ]]; then
  ok "default values agree"
else
  err "default values differ between manifest and Logic.js"
fi

echo "version"
mv=$(jq -r .version "$M")
lv=$(grep -oE '^T\.version = "[^"]+"' hypr/taskbox.lua | grep -oE '"[^"]+"' | tr -d '"')
cv=$(grep -oE '^## [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | head -1 | cut -c4-)
[[ $mv == "$lv" ]] && ok "hypr/taskbox.lua is $lv" || err "manifest $mv vs hypr/taskbox.lua $lv"
[[ $mv == "$cv" ]] && ok "CHANGELOG top entry is $cv" || err "manifest $mv vs CHANGELOG $cv"

exit $fail
