.pragma library

// Pure logic for Taskbox: no QML, no Quickshell, no side effects beyond the
// state objects passed in. Everything here is unit-tested with Node
// (tests/unit/logic.test.mjs), so keep it plain ES5-compatible JavaScript
// with top-level function declarations only (the QML engine and the Node test
// loader both rely on that).

// ------------------------------------------------------------------ settings

var DEFAULTS = {
  maxWidth: 200,
  minWidth: 44,
  showTitle: true,
  closeButton: "hover",
  middleClickClose: true,
  clickToMinimize: true,
  showMinimized: true,
  minimizeWorkspace: "minimized",
  highlightColor: ""
}

var CLOSE_BUTTON_MODES = ["hover", "always", "never"]

// Special workspaces other tools park minimized windows on, so their windows
// show (dimmed, restorable) here too:
//   minimized          hyprbars "minimize" buttons, omadock, Taskbox itself
//   omarchy-minimized  window-shelf, qol-desktop-plus
var KNOWN_MINIMIZE_WORKSPACES = ["minimized", "omarchy-minimized"]

// shell.json values may be JSON booleans/numbers or strings (omarchy bar set
// without --json stores strings), so accept both.
function toBool(value, fallback) {
  if (value === true || value === "true") return true
  if (value === false || value === "false") return false
  return fallback
}

function toInt(value, fallback, min, max) {
  var n = Math.round(Number(value))
  if (value === null || value === undefined || value === "" || !isFinite(n)) n = fallback
  if (min !== undefined && n < min) n = min
  if (max !== undefined && n > max) n = max
  return n
}

// Special workspace names go into Hyprland selectors; keep them boring.
function workspaceName(value, fallback) {
  var name = String(value === undefined || value === null ? "" : value).replace(/^special:/, "")
  return /^[A-Za-z0-9_.-]{1,64}$/.test(name) ? name : fallback
}

function normalizeSettings(raw) {
  raw = raw || {}
  var maxWidth = toInt(raw.maxWidth, DEFAULTS.maxWidth, 24, 2000)
  var closeButton = String(raw.closeButton === undefined ? DEFAULTS.closeButton : raw.closeButton)
  return {
    maxWidth: maxWidth,
    minWidth: toInt(raw.minWidth, Math.min(DEFAULTS.minWidth, maxWidth), 24, maxWidth),
    showTitle: toBool(raw.showTitle, DEFAULTS.showTitle),
    closeButton: CLOSE_BUTTON_MODES.indexOf(closeButton) === -1 ? DEFAULTS.closeButton : closeButton,
    middleClickClose: toBool(raw.middleClickClose, DEFAULTS.middleClickClose),
    clickToMinimize: toBool(raw.clickToMinimize, DEFAULTS.clickToMinimize),
    showMinimized: toBool(raw.showMinimized, DEFAULTS.showMinimized),
    minimizeWorkspace: workspaceName(raw.minimizeWorkspace, DEFAULTS.minimizeWorkspace),
    // "" = the theme's default highlight; anything unparseable falls back to it
    highlightColor: parseHexColor(raw.highlightColor)
  }
}

// ------------------------------------------------------------------ colours
//
// The custom highlight replaces the tint of the button background; the
// widget keeps applying its usual transparency levels on top, so any colour
// sits at the same visual weight as the stock (theme foreground) highlight.

function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x) }

// "#abc", "#aabbcc", "aabbcc" (any case, surrounding space) -> "#aabbcc";
// anything else (incl. 8-digit forms, whose alpha order is ambiguous) -> "".
function parseHexColor(value) {
  var v = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (v.charAt(0) === "#") v = v.slice(1)
  if (/^[0-9a-f]{3}$/.test(v)) v = v.charAt(0) + v.charAt(0) + v.charAt(1) + v.charAt(1) + v.charAt(2) + v.charAt(2)
  return /^[0-9a-f]{6}$/.test(v) ? "#" + v : ""
}

function hexToRgb(hex) {
  var v = parseHexColor(hex)
  if (!v) return null
  return { r: parseInt(v.slice(1, 3), 16), g: parseInt(v.slice(3, 5), 16), b: parseInt(v.slice(5, 7), 16) }
}

// Channels 0-255 (fractional ok) -> "#rrggbb".
function rgbToHex(r, g, b) {
  function part(x) {
    var n = Math.round(Math.max(0, Math.min(255, Number(x) || 0)))
    return (n < 16 ? "0" : "") + n.toString(16)
  }
  return "#" + part(r) + part(g) + part(b)
}

// h in degrees [0, 360), s/l/v in [0, 1].
function rgbToHsl(rgb) {
  var r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2, d = max - min, h = 0, s = 0
  if (d > 0) {
    s = d / (1 - Math.abs(2 * l - 1))
    if (max === r) h = ((g - b) / d) % 6
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h *= 60
    if (h < 0) h += 360
  }
  return { h: h, s: clamp01(s), l: l }
}

function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360
  var c = (1 - Math.abs(2 * l - 1)) * s
  var x = c * (1 - Math.abs((h / 60) % 2 - 1))
  var m = l - c / 2
  var p = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
    : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x]
  return { r: (p[0] + m) * 255, g: (p[1] + m) * 255, b: (p[2] + m) * 255 }
}

function rgbToHsv(rgb) {
  var r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  var h = rgbToHsl(rgb).h
  return { h: h, s: max === 0 ? 0 : d / max, v: max }
}

function hsvToRgb(h, s, v) {
  var l = v * (1 - s / 2)
  var sl = (l === 0 || l === 1) ? 0 : (v - l) / Math.min(l, 1 - l)
  return hslToRgb(h, sl, l)
}

function hsvToHex(h, s, v) {
  var c = hsvToRgb(h, clamp01(s), clamp01(v))
  return rgbToHex(c.r, c.g, c.b)
}

// Five highlight colours that complement the theme's accent: its complement,
// the two split-complements and the two triads — at the lightness of the
// current highlight's tint (the bar foreground), so they read at the same
// weight once the button's transparency is applied. A near-grey accent gets
// a moderate saturation so the suggestions aren't all grey.
var HARMONY_OFFSETS = [180, 150, 210, 120, 240]

function highlightSuggestions(accentHex, baseHex) {
  var accent = hexToRgb(accentHex) || { r: 217, g: 123, b: 63 }
  var base = hexToRgb(baseHex) || { r: 202, g: 204, b: 204 }
  var a = rgbToHsl(accent)
  var lightness = Math.max(0.35, Math.min(0.85, rgbToHsl(base).l))
  var saturation = a.s < 0.1 ? 0.5 : Math.max(0.35, Math.min(0.75, a.s))
  return HARMONY_OFFSETS.map(function(offset) {
    var c = hslToRgb(a.h + offset, saturation, lightness)
    return rgbToHex(c.r, c.g, c.b)
  })
}

// ------------------------------------------------------------------ quoting

// POSIX single-quote a value for bash.
function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// A Lua double-quoted string literal.
function luaString(value) {
  return "\"" + String(value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, "\\\"")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\0/g, "\\0") + "\""
}

// `Taskbox.<fn>("a", "b")`, the expression `hyprctl dispatch` evaluates.
// Every argument is passed as a string.
function luaCall(fn, args) {
  if (!/^[a-z_]+$/.test(String(fn))) throw new Error("bad Taskbox function name: " + fn)
  return "Taskbox." + fn + "(" + (args || []).map(luaString).join(", ") + ")"
}

function dispatchCommand(expr) {
  return "hyprctl dispatch " + shellQuote(expr) + " >/dev/null 2>&1"
}

// ------------------------------------------------------------------ addresses

// Hyprland prints addresses as 0x…; Quickshell may drop the prefix.
function hexAddress(address) {
  return "0x" + String(address).replace(/^0x/i, "").toLowerCase()
}

// Map key for an address, independent of prefix and case.
function addressKey(address) {
  return String(address).replace(/^0x/i, "").toLowerCase()
}

// ------------------------------------------------------------------ events

// Hyprland raw events -> { type, … } or null. `name`/`data` are the parts
// either side of the first ">>" on the event socket.
function parseEvent(name, data) {
  if (name === "configreloaded") return { type: "reloaded" }
  if (name !== "custom") return null
  data = String(data)
  if (data === "taskbox-alt>>1") return { type: "alt", held: true }
  if (data === "taskbox-alt>>0") return { type: "alt", held: false }
  if (data.indexOf("taskbox>>attached") === 0) {
    var parts = data.split(",")
    return { type: "attached", version: parts.length > 1 ? parts[1] : "" }
  }
  if (data.indexOf("taskbox>>origins,") === 0)
    return { type: "origins", origins: parseOrigins(data.slice("taskbox>>origins,".length)) }
  return null
}

// "0xabc=3;0xdef=5" -> { abc: 3, def: 5 } (keys via addressKey).
function parseOrigins(text) {
  var result = {}
  var pairs = String(text || "").split(";")
  for (var i = 0; i < pairs.length; i++) {
    var kv = pairs[i].split("=")
    if (kv.length !== 2 || !kv[0]) continue
    var id = Number(kv[1])
    if (id > 0 && Math.floor(id) === id) result[addressKey(kv[0])] = id
  }
  return result
}

// ------------------------------------------------------------------ window model
//
// The QML side maps each Hyprland toplevel to a plain record:
//   { key, workspaceId, workspaceName, activated }
// and keeps one mutable `state` per widget:
//   { next, seq: {key: n}, origin: {key: workspaceId} }

function newState() {
  return { next: 0, seq: {}, origin: {} }
}

// Forget windows that no longer exist. Hyprland addresses are pointers and
// get reused, so a stale entry would give a new window an old position (or
// an old origin).
function prune(state, liveKeys) {
  var live = {}
  for (var i = 0; i < liveKeys.length; i++) live[liveKeys[i]] = true
  for (var k in state.seq) if (!live[k]) delete state.seq[k]
  for (var o in state.origin) if (!live[o]) delete state.origin[o]
}

// Record where every window on a regular workspace is, and return the
// records of minimized windows that belong on `workspaceId`'s taskbar. A
// minimized window with no known origin shows everywhere.
// Every special workspace whose windows count as minimized: the one Taskbox
// minimizes to, plus the conventions other tools use.
function minimizeWorkspaces(own) {
  var names = [own]
  for (var i = 0; i < KNOWN_MINIMIZE_WORKSPACES.length; i++)
    if (names.indexOf(KNOWN_MINIMIZE_WORKSPACES[i]) === -1) names.push(KNOWN_MINIMIZE_WORKSPACES[i])
  return names
}

function isMinimizedWorkspace(workspaceName, own) {
  var name = String(workspaceName || "")
  if (name.indexOf("special:") !== 0) return false
  return minimizeWorkspaces(own).indexOf(name.slice(8)) !== -1
}

function minimizedFor(records, state, workspaceId, minimizeName, showMinimized) {
  var result = []
  for (var i = 0; i < records.length; i++) {
    var r = records[i]
    if (r.workspaceId > 0) state.origin[r.key] = r.workspaceId
    else if (showMinimized && isMinimizedWorkspace(r.workspaceName, minimizeName)) {
      var from = state.origin[r.key]
      if (from === undefined || from === workspaceId) result.push(r)
    }
  }
  return result
}

// Sort records oldest-first (first time each key was seen).
function ordered(records, state) {
  for (var i = 0; i < records.length; i++) {
    var k = records[i].key
    if (state.seq[k] === undefined) state.seq[k] = state.next++
  }
  return records.slice().sort(function(a, b) { return state.seq[a.key] - state.seq[b.key] })
}

// ------------------------------------------------------------------ layout

// How many buttons fit, whether the rest overflow into "+N", and each
// button's size along the bar.
function layout(count, available, minExtent, maxExtent, overflowExtent, spacing) {
  if (count <= 0) return { fitCount: 0, overflowing: false, buttonExtent: maxExtent }
  var fit = count
  if (count * minExtent + (count - 1) * spacing > available) {
    var room = available - overflowExtent - spacing
    fit = Math.max(1, Math.min(count - 1, Math.floor((room + spacing) / (minExtent + spacing))))
  }
  var overflowing = fit < count
  var space = available - (overflowing ? overflowExtent + spacing : 0)
  var extent = Math.floor((space - (fit - 1) * spacing) / fit)
  return {
    fitCount: fit,
    overflowing: overflowing,
    buttonExtent: Math.max(minExtent, Math.min(maxExtent, extent))
  }
}

// Total length the widget occupies along the bar.
function contentExtent(shownCount, buttonExtent, overflowing, overflowExtent, spacing, trailingGap) {
  if (shownCount <= 0 && !overflowing) return 0
  return shownCount * buttonExtent + Math.max(0, shownCount - 1) * spacing
    + (overflowing ? overflowExtent + spacing : 0) + trailingGap
}

// Split into shown / hidden, keeping the focused one visible (it takes the
// last shown slot). `isActive(item)` tells which is focused.
function pickShown(items, fitCount, isActive) {
  if (fitCount >= items.length) return { shown: items.slice(), hidden: [] }
  var shown = items.slice(0, fitCount)
  var active = null
  for (var i = 0; i < items.length; i++) if (isActive(items[i])) active = items[i]
  if (active && shown.indexOf(active) === -1 && shown.length > 0) shown[shown.length - 1] = active
  var hidden = items.filter(function(x) { return shown.indexOf(x) === -1 })
  return { shown: shown, hidden: hidden }
}

// Free length for the widget along the bar. `slots` are the other modules on
// this bar: { region, near, far, length } with near/far in bar coordinates
// along the bar axis. The widget sits first in the right/bottom section, so
// its far edge is the bar length minus margin minus every other module in
// that section; its near limit is the furthest edge of the left/center ones.
// Neither depends on the widget's own size (no feedback loop).
function freeSpace(barLength, slots, margin, trailingGap, padding, minimum) {
  var others = 0
  var edge = margin
  for (var i = 0; i < slots.length; i++) {
    var s = slots[i]
    if (s.region === "right") others += s.length
    else edge = Math.max(edge, s.far)
  }
  return Math.max(minimum, barLength - margin - others - edge - trailingGap - padding)
}

// ------------------------------------------------------------------ interaction

// What a left click on a button does.
function clickAction(minimized, activated, clickToMinimize, integrated) {
  if (minimized) return integrated ? "restore" : "none"
  if (activated && clickToMinimize && integrated) return "minimize"
  return "focus"
}

// Workspaces offered by the menu: 1-10 plus any other regular workspace.
function workspaceChoices(existingIds) {
  var ids = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  for (var i = 0; i < (existingIds || []).length; i++) {
    var id = existingIds[i]
    if (id > 0 && Math.floor(id) === id && ids.indexOf(id) === -1) ids.push(id)
  }
  return ids.sort(function(a, b) { return a - b })
}

// Where a drop on a workspaces-widget button should send a window, from the
// button delegate's properties (any workspaces widget, not just Omarchy's):
//   { workspace, workspaceId, modelData }
// The real Hyprland workspace wins over displayed numbers: per-monitor
// setups show "3" for what may be workspace 13, or use named workspaces.
// Returns a Hyprland workspace selector ("13", "name:dev") or "".
function dropTargetOf(delegate) {
  if (!delegate) return ""
  function realId(v) { return typeof v === "number" && v > 0 && Math.floor(v) === v }
  var ws = delegate.workspace
  if (ws && realId(ws.id)) return String(ws.id)
  if (realId(delegate.workspaceId)) return String(delegate.workspaceId)
  var m = delegate.modelData
  if (realId(m)) return String(m)
  if (m && typeof m === "object") {
    if (m.workspace && realId(m.workspace.id)) return String(m.workspace.id)
    if (realId(m.id)) return String(m.id)
    if (typeof m.name === "string" && workspaceName(m.name, "") === m.name && !/^special:/.test(m.name))
      return /^[0-9]+$/.test(m.name) ? m.name : "name:" + m.name
  }
  return ""
}

// Is `selector` (from dropTargetOf) the workspace a window is already on?
function sameWorkspace(selector, workspaceId, workspaceName) {
  if (!selector) return false
  if (selector.indexOf("name:") === 0) return selector.slice(5) === String(workspaceName)
  return selector === String(workspaceId)
}

// Omarchy labels workspace 10 as "0" (its key).
function workspaceLabel(id) {
  return id === 10 ? "0" : String(id)
}

// ------------------------------------------------------------------ icons

// Names to try against desktop entries / the icon theme, most specific first.
function iconCandidates(appId, initialClass) {
  var out = []
  function add(v) { if (v && out.indexOf(v) === -1) out.push(v) }
  appId = String(appId || "")
  add(appId)
  // Chromium/Brave/Edge "app mode" windows (Omarchy web apps) are classed
  // chrome-<host>__<path>-<profile>: matched by host elsewhere (webAppHost);
  // the name heuristics below would only produce junk or the browser icon.
  if (webAppHost(appId)) return out
  add(appId.toLowerCase())
  add(String(initialClass || ""))
  if (appId.indexOf(".") > 0) add(appId.split(".").pop().toLowerCase())
  add(appId.replace(/[-_ ].*$/, "").toLowerCase())
  return out
}

// "chrome-discord.com__channels_@me-Default" -> "discord.com"
function webAppHost(appId) {
  var m = /^(?:chrome|chromium|brave|msedge|vivaldi)-([a-z0-9.-]+\.[a-z0-9-]+)_/i.exec(String(appId || ""))
  return m ? m[1].toLowerCase() : ""
}

// Host of the first http(s) URL in a desktop entry's Exec line.
function urlHost(execString) {
  var m = /https?:\/\/([a-z0-9.-]+)/i.exec(String(execString || ""))
  return m ? m[1].toLowerCase() : ""
}

// ------------------------------------------------------------------ commands

// Toggle the hover tag: untag the previous window, tag the next.
function hoverCommand(previous, next) {
  var cmds = []
  function tag(address, sign) {
    return dispatchCommand("hl.dsp.window.tag({ tag = \"" + sign + "taskbox-hover\", window = \"address:"
      + hexAddress(address) + "\" })")
  }
  if (previous) cmds.push(tag(previous, "-"))
  if (next) cmds.push(tag(next, "+"))
  return cmds.join("; ")
}

// Run when a widget instance is destroyed. Instances also die on shell
// restarts, monitor changes, code reloads, moves, and when a tray/drawer host
// closes, so decide a moment later — and only by Omarchy's own notion of
// "enabled" (the id appears anywhere in shell.json: bar layout, plugins[],
// or a host like a tray or drawer), asked from the running shell. Reload
// Hyprland (dropping what hypr/taskbox.lua added) only when the shell answers
// and says Taskbox is disabled or gone. flock collapses several instances.
// cleanupScript is separate so tests can run it against stub commands.
function cleanupScript(moduleName) {
  return "sleep ${TASKBOX_CLEANUP_DELAY:-2}; "
    + "list=$(omarchy-shell shell listPlugins 2>/dev/null) || exit 0; "
    + "[ -n \"$list\" ] || exit 0; "
    + "state=$(printf '%s' \"$list\" | jq -r --arg id " + shellQuote(moduleName)
    + " '[.[] | select(.id == $id) | .enabled][0] // \"absent\"' 2>/dev/null) || exit 0; "
    + "[ -n \"$state\" ] || exit 0; "
    + "[ \"$state\" = true ] || hyprctl reload >/dev/null 2>&1"
}

function cleanupCommand(moduleName) {
  return "flock -n \"${XDG_RUNTIME_DIR:-/tmp}/taskbox-cleanup.lock\" sh -c "
    + shellQuote(cleanupScript(moduleName)) + " >/dev/null 2>&1 &"
}

// `omarchy bar set` for one setting; booleans/numbers stored as JSON.
function saveSettingCommand(moduleName, key, value) {
  var json = typeof value === "boolean" || typeof value === "number"
  return "omarchy bar set " + shellQuote(moduleName) + " " + shellQuote(key) + " "
    + shellQuote(String(value)) + (json ? " --json" : "") + " >/dev/null 2>&1"
}
