import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "lib/Logic.js" as Logic

// IPC for bug reports, tests and AI agents:
//   omarchy-shell mourningazazel.taskbox <function> [args]
// One per widget instance, but only the primary instance's is enabled (see
// Taskbox.ipcPrimary); it answers for every monitor via bar.moduleWidgets().
// Functions that act on a window find the instance whose taskbar shows it.
//
// The helpers live outside the IpcHandler: it publishes every function and
// property it has, and only string/bool/int ones can cross IPC.
Item {
  id: api
  visible: false

  required property var widget   // this instance's Taskbox

  function instances() {
    var host = widget.host
    return host && typeof host.moduleWidgets === "function" ? host.moduleWidgets(widget.moduleName) : [widget]
  }

  // The instance on the focused monitor (Omarchy's summon picks the same).
  function focusedInstance() {
    var list = instances()
    var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < list.length; i++)
      if (list[i].screenRef && list[i].screenRef.name === focused) return list[i]
    return list.length > 0 ? list[0] : widget
  }

  // { widget, toplevel } for the taskbar listing that window, or null.
  function instanceShowing(address) {
    var list = instances()
    var key = Logic.addressKey(address)
    for (var i = 0; i < list.length; i++) {
      var w = list[i].windows
      for (var j = 0; j < w.length; j++) if (list[i].keyOf(w[j]) === key) return { widget: list[i], toplevel: w[j] }
    }
    return null
  }

  IpcHandler {
    target: "mourningazazel.taskbox"
    enabled: api.widget.ipcPrimary

    // JSON snapshot of every instance (one per monitor).
    function state(): string {
      return JSON.stringify(api.instances().map(function(w) { return w.snapshot() }))
    }

    // Re-run the compatibility self-check; JSON list of unavailable features.
    function check(): string {
      var all = []
      api.instances().forEach(function(w) {
        w.checkCompat().forEach(function(m) { if (all.indexOf(m) === -1) all.push(m) })
      })
      return JSON.stringify(all)
    }

    // Hover highlight a window as if the pointer were on its button ("" clears).
    function hover(address: string): string {
      api.instances().forEach(function(w) { w.clearHover() })
      if (!address) return "cleared"
      var hit = api.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      hit.widget.setHover(hit.toplevel, true)
      return "ok"
    }

    // Rest the pointer on a window's button, for its hover preview ("" hides
    // them). Answers whether that window gets one.
    function preview(address: string): string {
      api.instances().forEach(function(w) { w.preview.hide() })
      if (!address) return "hidden"
      var hit = api.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      var button = hit.widget.buttonFor(hit.toplevel)
      if (!button) return "not shown (in +N)"
      return hit.widget.preview.hover(button, hit.toplevel, true) ? "ok" : "no preview for this window"
    }

    // Tests: make captures fail, to check the preview's icon fallback.
    function previewFailure(on: bool): string {
      api.instances().forEach(function(w) { w.preview.simulateFailure = on })
      return String(on)
    }

    // Left-click a window's button, as the user would (restore / minimize /
    // focus), on the taskbar of the monitor showing it.
    function click(address: string): string {
      var hit = api.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      hit.widget.activate(hit.toplevel)
      return "ok"
    }

    // Open a window's right-click menu.
    function menu(address: string): string {
      var hit = api.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      hit.widget.openMenu(hit.widget.buttonFor(hit.toplevel), hit.toplevel)
      return "ok"
    }

    // Open the overflow list / settings on the focused monitor's taskbar (as
    // Omarchy's own summon does), or close any popup.
    function overflow(): string { var w = api.focusedInstance(); w.showPopup("overflow"); return w.popup }
    function settings(): string { var w = api.focusedInstance(); w.open(); return w.popup }
    function colorPicker(): string { var w = api.focusedInstance(); w.open(); w.pickerOpen = true; return w.popup }
    function closePopups(): void { api.instances().forEach(function(w) { w.close() }) }

    // How an app id's icon is resolved (bypasses the cache).
    function icon(appId: string): string {
      var apps = DesktopEntries.applications.values
      var hosts = []
      for (var i = 0; i < apps.length; i++) {
        var h = Logic.urlHost(apps[i].execString)
        if (h) hosts.push(h)
      }
      return JSON.stringify({
        appId: appId,
        webAppHost: Logic.webAppHost(appId),
        candidates: Logic.iconCandidates(appId, ""),
        desktopEntries: apps.length,
        webAppHosts: hosts,
        result: api.widget.icons.lookup(appId, "")
      })
    }

    // The workspace targets drag-and-drop would hit along each monitor's bar:
    // { "<screen>": [{ id, at }, …] }.
    function dropTargets(): string {
      var out = {}
      api.instances().forEach(function(w) { out[w.screenRef ? w.screenRef.name : "?"] = w.sampleDropTargets() })
      return JSON.stringify(out)
    }
  }
}
