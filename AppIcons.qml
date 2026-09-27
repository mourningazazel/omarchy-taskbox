import QtQuick
import Quickshell
import "lib/Logic.js" as Logic

// App icons for windows: Omarchy web apps by the URL host in their desktop
// entry (they have no StartupWMClass), then desktop entries for each
// candidate name (Logic.iconCandidates), then the icon theme directly.
//
// Results are cached in a plain object mutated in place: iconFor() runs
// inside bindings, and assigning a property there would re-trigger them (a
// binding loop). _rev is bumped only from outside, to invalidate; the cache
// is rebuilt when the installed apps change.
Item {
  id: icons
  visible: false

  property int _rev: 0
  readonly property var _cache: ({ byApp: {}, web: null })

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      icons._cache.byApp = {}
      icons._cache.web = null
      icons._rev++
    }
  }

  function appIdOf(t) {
    if (!t) return ""
    if (t.wayland && t.wayland.appId) return t.wayland.appId
    var ipc = t.lastIpcObject
    return ipc && ipc["class"] ? ipc["class"] : ""
  }

  function resolve(name) {
    if (!name) return ""
    if (name.charAt(0) === "/") return "file://" + name
    return Quickshell.iconPath(name, true) || ""
  }

  // host -> icon name, from every desktop entry with a URL in its Exec line.
  function webIcon(host) {
    if (!_cache.web) {
      var map = {}
      var apps = DesktopEntries.applications.values
      for (var i = 0; i < apps.length; i++) {
        var h = Logic.urlHost(apps[i].execString)
        if (h && apps[i].icon && map[h] === undefined) map[h] = apps[i].icon
      }
      _cache.web = map
    }
    return resolve(_cache.web[host] || "")
  }

  // { path, via }: the icon for an app id, and how it was found (for the
  // `icon` IPC call).
  function lookup(id, initial) {
    var host = Logic.webAppHost(id)
    if (host) {
      var web = webIcon(host)
      if (web) return { path: web, via: "web app host " + host }
    }
    var candidates = Logic.iconCandidates(id, initial)
    for (var i = 0; i < candidates.length; i++) {
      var entry = DesktopEntries.heuristicLookup(candidates[i])
      var fromEntry = entry && entry.icon ? resolve(entry.icon) : ""
      if (fromEntry) return { path: fromEntry, via: "desktop entry " + entry.id + " for " + candidates[i] }
    }
    for (var j = 0; j < candidates.length; j++) {
      var themed = resolve(candidates[j])
      if (themed) return { path: themed, via: "icon theme " + candidates[j] }
    }
    return { path: Quickshell.iconPath("application-x-executable", true), via: "fallback" }
  }

  // Icon URL for a window (cached per app id + initial class).
  function iconFor(t) {
    var rev = _rev
    var id = appIdOf(t)
    var ipc = t ? t.lastIpcObject : null
    var initial = ipc && ipc.initialClass ? ipc.initialClass : ""
    var cacheKey = id + "|" + initial
    if (_cache.byApp[cacheKey]) return _cache.byApp[cacheKey]
    var found = lookup(id, initial)
    // Don't pin a fallback: the app may simply not be indexed yet.
    if (found.via !== "fallback") _cache.byApp[cacheKey] = found.path
    return found.path
  }
}
