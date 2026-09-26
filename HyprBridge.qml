import QtQuick
import Quickshell.Hyprland
import "lib/Logic.js" as Logic

// Everything that talks to Hyprland: loading hypr/taskbox.lua, calling its
// Taskbox.* actions, and turning its events (Alt, attached, origins) into
// properties and signals. One per widget instance (i.e. per monitor).
//
//   widget ──hyprctl dispatch 'Taskbox.fn(...)'──► Hyprland Lua (_G.Taskbox)
//   widget ◄── Hyprland.rawEvent custom>>taskbox… ───┘
Item {
  id: bridge
  visible: false

  property var bar: null
  property string luaPath: ""

  // Hyprland's Lua config (Omarchy 4.0+) is required for everything here.
  readonly property bool luaConfig: Hyprland.usingLua
  // True once hypr/taskbox.lua answered Taskbox.attach() in this Lua state.
  property bool integrated: false
  property string version: ""

  // The bar never has keyboard focus, so Alt comes from binds in the Lua.
  property bool altHeld: false

  // Address of the window currently hovered on the taskbar ("" = none).
  property string hoverAddress: ""
  property string _taggedAddress: ""
  property bool _helloDone: false
  property int _attachAttempts: 0

  signal originsReceived(var origins)

  function run(command) {
    if (bar && command) bar.run(command)
  }

  // Taskbox.<fn>(args…) in Hyprland; ignored until the Lua side is loaded.
  function call(fn, args) {
    if (integrated) run(Logic.dispatchCommand(Logic.luaCall(fn, args || [])))
  }

  function attach() {
    if (!bar || !luaConfig || !luaPath) return
    _attachAttempts++
    run(Logic.dispatchCommand("dofile(" + Logic.luaString(luaPath) + ")")
      + " && " + Logic.dispatchCommand("Taskbox.attach()"))
  }

  // Hyprland's socket may not be ready when the shell starts (login): keep
  // retrying for about a minute until the Lua answers.
  Timer {
    interval: 5000
    repeat: true
    running: !bridge.integrated && bridge.luaConfig && bridge.bar !== null && bridge._attachAttempts < 12
    onTriggered: bridge.attach()
  }

  onBarChanged: Qt.callLater(attach)
  onLuaConfigChanged: Qt.callLater(attach)

  function clearAlt() { altHeld = false }

  Timer {
    // Hyprland can drop the Alt release (e.g. the window under it was
    // killed), so a press only counts for a while.
    id: altExpiry
    interval: 10000
    onTriggered: bridge.altHeld = false
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var e = Logic.parseEvent(event.name, event.data)
      if (!e) return
      if (e.type === "reloaded") {
        // A config reload wiped the Lua state: load it again.
        bridge.integrated = false
        bridge._attachAttempts = 0
        Qt.callLater(bridge.attach)
      } else if (e.type === "alt") {
        bridge.altHeld = e.held
        if (e.held) altExpiry.restart()
      } else if (e.type === "attached") {
        bridge.version = e.version
        bridge.integrated = true
        if (!bridge._helloDone) {
          bridge._helloDone = true
          bridge.call("hello", [])
        }
      } else if (e.type === "origins") {
        bridge.originsReceived(e.origins)
      }
    }
  }

  // ------------------------------------------------------------ hover highlight
  // The hovered window gets the `taskbox-hover` tag (styled by the rule the
  // Lua installs). Sweeping across buttons coalesces into one dispatch.
  function setHover(address, on) {
    var a = address ? Logic.hexAddress(address) : ""
    if (on) hoverAddress = a
    else if (hoverAddress === a) hoverAddress = ""
    hoverSync.restart()
  }

  function clearHover() {
    hoverAddress = ""
    hoverSync.restart()
  }

  Timer {
    id: hoverSync
    interval: 40
    onTriggered: bridge.applyHover()
  }

  function applyHover() {
    var next = integrated ? hoverAddress : ""
    if (next === _taggedAddress || !bar) return
    run(Logic.hoverCommand(_taggedAddress, next))
    _taggedAddress = next
  }

  // Called by the widget when it's destroyed.
  function shutdown(moduleName) {
    if (_taggedAddress) run(Logic.hoverCommand(_taggedAddress, ""))
    // If Taskbox was taken off the bar (not just restarted), reload Hyprland
    // to drop what the Lua added. See Logic.cleanupCommand.
    if (integrated) run(Logic.cleanupCommand(moduleName))
  }
}
