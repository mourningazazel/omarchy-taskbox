import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "lib/Logic.js" as Logic

// Windows-style taskbar for the Omarchy bar: one button per window on this
// monitor's active workspace (plus its minimized windows), oldest on the left.
// It sits at the front of the right section and grows toward the left
// section; buttons share the free space, clamped to [minWidth, maxWidth].
// On a left/right bar it becomes a column of icon-only buttons.
//
// Pure logic (settings, ordering, layout, commands) lives in lib/Logic.js and
// is unit-tested; Hyprland I/O lives in HyprBridge.qml; the Hyprland side is
// hypr/taskbox.lua. See AGENTS.md for the architecture.
BarWidget {
  id: root
  moduleName: "mourningazazel.taskbox"

  // ------------------------------------------------------------------ host
  // Only ever talk to the bar through `host`, and only with the members
  // Omarchy 4.0.4+ gives third-party widgets (PluginBarApi: theme values,
  // run, tooltips, popouts, moduleWidgets, layoutConfig). The bar's layout is
  // read from our own visual ancestors instead (see mySlot / barSlots), which
  // Omarchy documents as reachable. `emulateFacade` (tests) swaps in an exact
  // stand-in for that facade on older Omarchy.
  readonly property bool emulateFacade: !!settings && (settings.emulateFacade === true || settings.emulateFacade === "true")
  BarFacade { id: facadeShim; real: root.bar }
  readonly property var host: emulateFacade ? facadeShim : bar

  // ---------------------------------------------------------------- settings
  readonly property var config: Logic.normalizeSettings(settings)
  readonly property int maxWidth: config.maxWidth
  readonly property int minWidth: config.minWidth
  readonly property bool showTitle: config.showTitle
  readonly property string closeButton: config.closeButton
  readonly property bool middleClickClose: config.middleClickClose
  readonly property bool clickToMinimize: config.clickToMinimize
  readonly property bool showMinimized: config.showMinimized
  readonly property string minimizeWorkspace: config.minimizeWorkspace

  function saveSetting(key, value) {
    if (host) host.run(Logic.saveSettingCommand(moduleName, key, value))
  }

  // ------------------------------------------------------------------ theme
  // Per-value fallbacks: replacement bars don't all provide every value.
  function hostValue(name, fallback) {
    var v = host ? host[name] : undefined
    return v === undefined || v === null || v === "" ? fallback : v
  }
  readonly property color fg: hostValue("barForeground", Color.foreground)
  readonly property color accent: Color.accent
  readonly property color urgentColor: hostValue("urgent", Color.urgent)
  readonly property string fontFamily: hostValue("fontFamily", Style.font.family)
  readonly property int spacing: Style.space(4)
  readonly property int trailingGap: Style.space(8)

  // ------------------------------------------------------------ hyprland
  HyprBridge {
    id: hypr
    bar: root.host
    luaPath: String(Qt.resolvedUrl("hypr/taskbox.lua")).replace(/^file:\/\//, "")
    onOriginsReceived: function(origins) {
      for (var key in origins) root._state.origin[key] = origins[key]
      root._stateRev++
    }
  }

  readonly property bool integrated: hypr.integrated
  readonly property bool altHeld: hypr.altHeld

  function call(fn, args) { hypr.call(fn, args) }

  // ------------------------------------------------------------ self-check
  // Taskbox leans on a few Omarchy internals (see AGENTS.md). Shortly after
  // start, list any feature whose prerequisite is missing, log it once and
  // show it in the settings popup, so an Omarchy change degrades one feature
  // visibly instead of misbehaving silently.
  property var unavailable: []

  function checkCompat() {
    var missing = []
    if (!host || typeof host.run !== "function") missing.push("everything that talks to Hyprland (bar.run)")
    if (!hypr.luaConfig) missing.push("window actions, drag, minimize, hover and Alt (needs Hyprland's Lua config, Omarchy 4.0+)")
    else if (!integrated) missing.push("window actions, drag, minimize, hover and Alt (hypr/taskbox.lua didn't load)")
    var slot = mySlot()
    if (!slot) missing.push("automatic button sizing and dragging (bar slot not found)")
    else if (!reorderArea(slot)) missing.push("dragging buttons (bar reorder area not found)")
    if (slot && barSlots().length === 0) missing.push("automatic button sizing (bar sections not found)")
    unavailable = missing
    if (missing.length > 0) console.warn("[taskbox] unavailable here: " + missing.join("; "))
    return missing
  }

  Timer {
    interval: 6000
    running: root.bar !== null
    onTriggered: root.checkCompat()
  }

  // ------------------------------------------------------------ window model
  readonly property var screenRef: root.QsWindow.window ? root.QsWindow.window.screen : null
  readonly property var monitor: screenRef ? Hyprland.monitorFor(screenRef) : null
  readonly property var workspace: monitor ? monitor.activeWorkspace : null

  // Order/origin state (see Logic.newState). Mutated in place by the model
  // bindings (never reassigned, so they don't re-trigger themselves);
  // _stateRev is bumped when it changes from outside a binding.
  readonly property var _state: Logic.newState()
  property int _stateRev: 0

  function keyOf(t) { return Logic.addressKey(t.address) }

  // Minimized = parked on Taskbox's minimize workspace or one of the other
  // conventions (Logic.KNOWN_MINIMIZE_WORKSPACES).
  function isMinimized(t) {
    return !!(t && t.workspace && Logic.isMinimizedWorkspace(t.workspace.name, minimizeWorkspace))
  }

  // Every toplevel as a plain record for Logic; also prunes closed windows
  // (addresses are reused).
  readonly property var _records: {
    var rev = _stateRev
    var all = Hyprland.toplevels.values
    var records = []
    var keys = []
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      var ws = t.workspace
      var key = keyOf(t)
      keys.push(key)
      if (!ws) continue
      records.push({ key: key, workspaceId: ws.id, workspaceName: ws.name, activated: t.activated, toplevel: t })
    }
    Logic.prune(_state, keys)
    return records
  }

  // This workspace's windows plus the minimized ones that belong here, in
  // first-seen order.
  readonly property var windows: {
    if (!workspace) return []
    var here = _records.filter(function(r) { return r.workspaceId === workspace.id })
    var parked = Logic.minimizedFor(_records, _state, workspace.id, minimizeWorkspace, showMinimized)
    return Logic.ordered(here.concat(parked), _state).map(function(r) { return r.toplevel })
  }

  // ------------------------------------------------------------ sizing
  // Everything is measured along the bar: width on a top/bottom bar, height
  // on a left/right one (where buttons are icon-only squares).
  property real available: vertical ? barSize * 4 : maxWidth
  readonly property int count: windows.length
  readonly property int maxExtent: vertical ? barSize : maxWidth
  readonly property int minExtent: vertical ? barSize : minWidth
  readonly property int overflowExtent: vertical ? barSize : Style.space(30)

  readonly property var _layout: Logic.layout(count, available, minExtent, maxExtent, overflowExtent, spacing)
  readonly property int fitCount: _layout.fitCount
  readonly property bool overflowing: _layout.overflowing
  readonly property int buttonExtent: _layout.buttonExtent

  readonly property var _split: Logic.pickShown(windows, fitCount, function(t) { return t.activated })
  readonly property var shownWindows: _split.shown
  readonly property var hiddenWindows: _split.hidden

  readonly property real contentExtent:
    Logic.contentExtent(shownWindows.length, buttonExtent, overflowing, overflowExtent, spacing, trailingGap)

  // Stays mapped (at a sliver) while settings are open on an empty workspace,
  // so the popup has something to anchor to.
  visible: count > 0 || opened
  implicitWidth: !visible ? 0 : (vertical ? barSize : Math.max(contentExtent, 1))
  implicitHeight: !visible ? 0 : (vertical ? Math.max(contentExtent, 1) : barSize)

  // The bar's ModuleSlot wrapping this widget: our nearest ancestor that
  // hosts us as its activeItem.
  function mySlot() {
    for (var p = root.parent; p; p = p.parent)
      if (p.activeItem === root && p.region !== undefined) return p
    return null
  }

  function isSlot(item) {
    return !!item && item.region !== undefined && item.activeItem !== undefined && item.moduleName !== undefined
  }

  // Every module slot on this monitor's bar, found by walking our own bar
  // window's items (not descending into widgets). Replaces the host-only
  // bar.moduleSlots, which third-party widgets don't get from 4.0.4 on.
  function barSlots() {
    var win = root.QsWindow.window
    if (!win || !win.contentItem) return []
    var out = []
    var stack = [win.contentItem]
    for (var guard = 0; stack.length > 0 && guard < 4000; guard++) {
      var item = stack.pop()
      if (isSlot(item)) { out.push(item); continue }
      var kids = item.children
      for (var i = 0; i < kids.length; i++) stack.push(kids[i])
    }
    return out
  }

  // Free space along this monitor's bar (Logic.freeSpace), from the section
  // each slot is tagged with rather than live positions, which lag during
  // relayout. Our own size never feeds back into it.
  function recompute() {
    var win = root.QsWindow.window
    var slot = mySlot()
    if (!win) return
    if (!slot) {
      // Hosted outside a bar slot (a tray, a drawer, a replacement bar we
      // don't recognise): natural size, capped at half the screen.
      var natural = count * maxExtent + Math.max(0, count - 1) * spacing
      var cap = (vertical ? win.height : win.width) / 2
      var fallback = Math.max(minExtent, Math.min(natural, cap > 0 ? cap : natural))
      if (Math.abs(fallback - available) >= 1) available = fallback
      return
    }
    var others = []
    var slots = barSlots()
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i]
      if (s === slot || !s.visible || s.width <= 0 || s.height <= 0) continue
      var far = s.mapToItem(null, s.width, s.height)
      others.push({ region: s.region, far: vertical ? far.y : far.x, length: vertical ? s.height : s.width })
    }
    var next = Logic.freeSpace(vertical ? win.height : win.width, others,
      Style.space(8), trailingGap, Style.space(12), minExtent)
    if (Math.abs(next - available) >= 1) available = next
  }

  Timer {
    // Neighbours (clock, weather) change size without telling us.
    interval: 750
    running: root.bar !== null && root.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: root.recompute()
  }
  Connections {
    target: root.QsWindow.window
    ignoreUnknownSignals: true
    function onWidthChanged() { Qt.callLater(root.recompute) }
    function onHeightChanged() { Qt.callLater(root.recompute) }
  }
  onCountChanged: Qt.callLater(recompute)
  onVerticalChanged: Qt.callLater(recompute)

  // Close what refers to a window that's gone (closed, or moved away).
  onWindowsChanged: {
    if (popup === "menu" && windows.indexOf(menuToplevel) === -1) close()
    if (dragging && windows.indexOf(dragToplevel) === -1) finishDrag(false)
  }

  // ------------------------------------------------------------ hover
  readonly property string hoverAddress: hypr.hoverAddress
  function setHover(t, on) { if (t) hypr.setHover(t.address, on) }
  function clearHover() { hypr.clearHover() }

  Component.onDestruction: {
    if (reorderBlocked) setReorderBlocked(false)
    hypr.shutdown(moduleName)
  }

  // ------------------------------------------------------------ bar reorder guard
  // The bar lays a press-grabbing MouseArea over every module slot so widgets
  // can be dragged around the layout; it only forwards plain clicks, so it
  // would swallow our button drags. Switch it off for our slot while the
  // pointer is on a button (or a drag is live), and restore its binding after.
  // The gaps between buttons still drag the taskbar widget itself — and so
  // does Alt+drag on a button: while Alt is held the guard is lifted, so the
  // press goes to the bar and it runs its own widget drag. (Clicks still fall
  // through to the buttons, so Alt+× force-kills as before.)
  readonly property bool reorderBlocked: !altHeld && (hoverAddress !== "" || dragging)
  onReorderBlockedChanged: setReorderBlocked(reorderBlocked)

  function reorderArea(slot) {
    var kids = slot ? slot.children : []
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i]
      if (k && k.canReorder !== undefined && k.dragThreshold !== undefined) return k
    }
    return null
  }

  function setReorderBlocked(blocked) {
    var slot = mySlot()
    var area = reorderArea(slot)
    if (!area) return
    if (blocked) area.enabled = false
    else area.enabled = Qt.binding(function() { return slot.visible && slot.width > 0 && slot.height > 0 })
  }

  // ------------------------------------------------------------ drag to workspace
  // Drag a button onto a number in the workspaces widget to send the window
  // there without following it (Taskbox.send in hypr/taskbox.lua, which also
  // fits it in and focuses it the next time that workspace is opened).
  property var dragToplevel: null
  property point dragPoint: Qt.point(0, 0)   // window-content coordinates
  property var dropTarget: null              // { id, x, y, width, height }
  readonly property bool dragging: dragToplevel !== null

  // Any workspaces widget on this bar (Omarchy's, a clone, or a third-party
  // one such as decent-workspaces or per-monitor-workspaces).
  function workspacesSlots() {
    return barSlots().filter(function(s) {
      return s.activeItem && s.activeItem !== root && /workspace/i.test(String(s.moduleName))
    })
  }

  function workspacesSlot() {
    var list = workspacesSlots()
    return list.length > 0 ? list[0] : null
  }

  // Walk down from each workspaces widget to the button under the point and
  // ask Logic.dropTargetOf what it stands for (real workspace id, a number,
  // or a named workspace). Returns { selector, x, y, width, height } or null.
  function workspaceAt(scenePoint) {
    var slots = workspacesSlots()
    for (var i = 0; i < slots.length; i++) {
      var item = slots[i].activeItem
      var local = item.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (local.x < 0 || local.y < 0 || local.x > item.width || local.y > item.height) continue
      for (var depth = 0; item && depth < 10; depth++) {
        if (item !== slots[i].activeItem) {
          var selector = Logic.dropTargetOf({ workspace: item.workspace, workspaceId: item.workspaceId, modelData: item.modelData })
          if (selector) {
            var r = item.mapToItem(null, 0, 0)
            return { selector: selector, x: r.x, y: r.y, width: item.width, height: item.height }
          }
        }
        var child = item.childAt(local.x, local.y)
        if (!child) break
        local = item.mapToItem(child, local.x, local.y)
        item = child
      }
    }
    return null
  }

  function beginDrag(t, scenePoint) {
    if (!integrated || !t) return false
    dragToplevel = t
    dragPoint = scenePoint
    dropTarget = workspaceAt(scenePoint)
    return true
  }

  function updateDrag(scenePoint) {
    if (!dragging) return
    dragPoint = scenePoint
    dropTarget = workspaceAt(scenePoint)
  }

  function finishDrag(commit) {
    var t = dragToplevel
    var target = dropTarget
    dragToplevel = null
    dropTarget = null
    if (!commit || !t || !target) return
    if (t.workspace && Logic.sameWorkspace(target.selector, t.workspace.id, t.workspace.name)) return
    sendToWorkspace(t, target.selector)
  }

  // Drawn on the bar window's content item so they can float over any module.
  Item {
    parent: root.QsWindow.window ? root.QsWindow.window.contentItem : root
    anchors.fill: parent
    z: 1000
    visible: root.dragging

    Rectangle {
      visible: root.dropTarget !== null
      x: root.dropTarget ? root.dropTarget.x : 0
      y: root.dropTarget ? root.dropTarget.y + (root.vertical ? 0 : Style.space(2)) : 0
      width: root.dropTarget ? root.dropTarget.width : 0
      height: root.dropTarget ? root.dropTarget.height - (root.vertical ? 0 : Style.space(4)) : 0
      radius: Style.cornerRadius
      color: Util.alpha(root.accent, 0.25)
      border.width: Math.max(1, Style.space(2))
      border.color: root.accent
    }

    // Ghost of the dragged button, following the pointer along the bar.
    Rectangle {
      width: root.vertical ? root.barSize - Style.space(6) : Math.min(root.buttonExtent, Style.space(160))
      height: root.vertical ? width : root.barSize - Style.space(6)
      x: root.vertical ? Style.space(3) : root.dragPoint.x - Style.space(10)
      y: root.vertical ? root.dragPoint.y - height / 2 : Style.space(3)
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.22)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.4)
      opacity: 0.9

      Image {
        id: ghostIcon
        anchors.left: parent.left
        anchors.leftMargin: root.vertical ? (parent.width - width) / 2 : Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        source: root.dragToplevel ? root.iconFor(root.dragToplevel) : ""
      }
      Text {
        visible: !root.vertical
        anchors.left: ghostIcon.right
        anchors.leftMargin: Style.space(6)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: root.dragToplevel ? (root.dragToplevel.title || "") : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // ------------------------------------------------------------ actions
  function hexAddress(t) { return Logic.hexAddress(t.address) }

  // Left-click: restore a minimized window, minimize the focused one (Windows
  // behaviour, if enabled), otherwise focus without moving the cursor.
  function activate(t) {
    if (!t) return
    var action = Logic.clickAction(isMinimized(t), t.activated, clickToMinimize, integrated)
    if (action === "restore") restoreWindow(t)
    else if (action === "minimize") minimizeWindow(t)
    else if (action === "focus") focusWindow(t)
  }

  function focusWindow(t) {
    if (!t) return
    if (integrated) call("focus", [hexAddress(t)])
    else if (t.wayland) t.wayland.activate()
  }

  function minimizeWindow(t) { if (t) call("minimize", [hexAddress(t), minimizeWorkspace]) }
  function restoreWindow(t) { if (t && workspace) call("restore", [hexAddress(t), String(workspace.id)]) }
  function sendToWorkspace(t, id) { if (t) call("send", [hexAddress(t), String(id)]) }
  function toggleFloating(t) { if (t) call("toggle_floating", [hexAddress(t)]) }
  function toggleMaximized(t) { if (t) call("toggle_maximized", [hexAddress(t)]) }

  // Graceful close asks the app to close (it may prompt to save). Force kill
  // SIGKILLs the owning process, which takes every window of that app with it.
  function closeWindow(t, force) {
    if (!t) return
    if (force && integrated) {
      hypr.clearAlt()
      call("kill", [hexAddress(t)])
    } else if (t.wayland) {
      t.wayland.close()
    } else {
      call("close", [hexAddress(t)])
    }
  }

  // The ×: Hyprland decides from the real Alt key state at click time
  // (Taskbox.close_or_kill), so a missed Alt release can't turn a close into
  // a SIGKILL. Without the Hyprland side it's always a graceful close.
  function closeFromButton(t) {
    if (!t) return
    if (integrated) {
      hypr.clearAlt()
      call("close_or_kill", [hexAddress(t)])
    } else {
      closeWindow(t, false)
    }
  }

  // ------------------------------------------------------------ icons
  function appIdOf(t) {
    if (!t) return ""
    if (t.wayland && t.wayland.appId) return t.wayland.appId
    var ipc = t.lastIpcObject
    return ipc && ipc["class"] ? ipc["class"] : ""
  }

  // Resolved icons per app id, and web-app icons per host (Omarchy web apps
  // have no StartupWMClass, so they're matched by the URL in their Exec
  // line). Both are rebuilt when the installed apps change.
  // Caches live in a plain object mutated in place: iconFor() runs inside
  // bindings, and assigning a property there would re-trigger them (a
  // binding loop). _iconRev is bumped only from outside, to invalidate.
  property int _iconRev: 0
  readonly property var _icons: ({ cache: {}, web: null })

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root._icons.cache = {}
      root._icons.web = null
      root._iconRev++
    }
  }

  function resolveIcon(name) {
    if (!name) return ""
    if (name.charAt(0) === "/") return "file://" + name
    return Quickshell.iconPath(name, true) || ""
  }

  function webIcon(host) {
    if (!_icons.web) {
      var map = {}
      var apps = DesktopEntries.applications.values
      for (var i = 0; i < apps.length; i++) {
        var h = Logic.urlHost(apps[i].execString)
        if (h && apps[i].icon && map[h] === undefined) map[h] = apps[i].icon
      }
      _icons.web = map
    }
    return resolveIcon(_icons.web[host] || "")
  }

  // Resolve an app's icon: web-app host match, then desktop entries for each
  // candidate name, then the icon theme directly. Returns how it was found,
  // for the `icon` IPC call.
  function lookupIcon(id, initial) {
    var host = Logic.webAppHost(id)
    if (host) {
      var web = webIcon(host)
      if (web) return { path: web, via: "web app host " + host }
    }
    var candidates = Logic.iconCandidates(id, initial)
    for (var i = 0; i < candidates.length; i++) {
      var entry = DesktopEntries.heuristicLookup(candidates[i])
      var fromEntry = entry && entry.icon ? resolveIcon(entry.icon) : ""
      if (fromEntry) return { path: fromEntry, via: "desktop entry " + entry.id + " for " + candidates[i] }
    }
    for (var j = 0; j < candidates.length; j++) {
      var themed = resolveIcon(candidates[j])
      if (themed) return { path: themed, via: "icon theme " + candidates[j] }
    }
    return { path: Quickshell.iconPath("application-x-executable", true), via: "fallback" }
  }

  function iconFor(t) {
    var rev = _iconRev
    var id = appIdOf(t)
    var ipc = t ? t.lastIpcObject : null
    var initial = ipc && ipc.initialClass ? ipc.initialClass : ""
    var cacheKey = id + "|" + initial
    if (_icons.cache[cacheKey]) return _icons.cache[cacheKey]
    var found = lookupIcon(id, initial)
    // Don't pin a fallback: the app may simply not be indexed yet.
    if (found.via !== "fallback") _icons.cache[cacheKey] = found.path
    return found.path
  }

  // ------------------------------------------------------------ view
  // ScriptModel diffs the list, so buttons for windows that didn't change
  // keep their delegates (hover, press and drag state survive other windows
  // opening/closing). A plain JS array model would rebuild every button.
  ScriptModel {
    id: shownModel
    values: root.shownWindows
  }

  ScriptModel {
    id: hiddenModel
    values: root.hiddenWindows
  }

  Grid {
    anchors.left: parent.left
    anchors.top: parent.top
    columns: root.vertical ? 1 : Math.max(1, root.shownWindows.length + 1)
    spacing: root.spacing
    visible: root.visible

    Repeater {
      id: buttons
      model: shownModel

      TaskButton {
        required property var modelData
        taskbar: root
        toplevel: modelData
        width: root.vertical ? root.barSize : root.buttonExtent
        height: root.vertical ? root.buttonExtent : root.barSize
      }
    }

    // "+N" overflow button.
    Item {
      visible: root.overflowing
      width: root.vertical ? root.barSize : root.overflowExtent
      height: root.vertical ? root.overflowExtent : root.barSize

      Rectangle {
        anchors.fill: parent
        anchors.margins: Style.space(3)
        radius: Style.cornerRadius
        color: Util.alpha(root.fg, overflowMouse.containsMouse || root.overflowOpen ? 0.18 : 0.08)
      }
      Text {
        anchors.centerIn: parent
        text: "+" + root.hiddenWindows.length
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      MouseArea {
        id: overflowMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.open()
          else root.showPopup("overflow")
        }
      }
    }
  }

  function buttonFor(t) {
    var i = shownWindows.indexOf(t)
    return i >= 0 ? buttons.itemAt(i) : null
  }

  // ------------------------------------------------------------ popups
  // One popup at a time: overflow list, a button's context menu, or settings.
  // open()/close()/opened are the bar's summon contract, so
  //   omarchy-shell shell toggle mourningazazel.taskbox
  // opens the settings popup.
  property string popup: ""          // "" | overflow | menu | settings
  property var menuToplevel: null
  property Item menuAnchor: null
  readonly property bool overflowOpen: popup === "overflow"
  readonly property bool opened: popup === "settings"

  // Owner for the bar's one-popup-at-a-time coordination. Deliberately not
  // the widget itself: the bar draws an "open" marker under the owning
  // widget, and across a wide taskbar it lands between buttons.
  readonly property QtObject popupOwner: QtObject {
    function close() { root.close() }
  }

  function showPopup(which) { popup = popup === which ? "" : which }
  function open() { popup = "settings" }
  function close() { popup = "" }

  function openMenu(anchorItem, t) {
    if (!t) return
    menuAnchor = anchorItem
    menuToplevel = t
    popup = "menu"
  }

  onOverflowingChanged: if (!overflowing && popup === "overflow") popup = ""

  PopupCard {
    id: overflowPopup
    anchorItem: root
    owner: root.popupOwner
    bar: root.host
    open: root.popup === "overflow"
    contentWidth: overflowPopup.fittedContentWidth(Style.space(280))
    contentHeight: overflowPopup.fittedContentHeight(overflowColumn.implicitHeight)

    Column {
      id: overflowColumn
      width: overflowPopup.contentWidth - overflowPopup.padding * 2
      spacing: Style.space(4)

      Repeater {
        model: hiddenModel

        TaskButton {
          required property var modelData
          taskbar: root
          toplevel: modelData
          width: overflowColumn.width
          height: root.barSize + Style.space(4)
          inPopup: true
        }
      }
    }
  }

  TaskMenu {
    taskbar: root
    anchorItem: root.menuAnchor || root
    toplevel: root.menuToplevel
    open: root.popup === "menu" && root.menuToplevel !== null
  }

  SettingsPopup {
    taskbar: root
    anchorItem: root
    open: root.popup === "settings"
  }

  // ------------------------------------------------------------ diagnostics
  // IPC for bug reports, tests and AI agents:
  //   omarchy-shell mourningazazel.taskbox state
  // Every instance registers the target (like Omarchy's own widgets); the one
  // that receives a call answers for all monitors via bar.moduleWidgets().
  function snapshot() {
    return {
      screen: screenRef ? screenRef.name : "",
      barLength: root.QsWindow.window ? Math.round(vertical ? root.QsWindow.window.height : root.QsWindow.window.width) : 0,
      ipcPrimary: ipcPrimary,
      workspace: workspace ? workspace.id : null,
      vertical: vertical,
      barSize: barSize,
      facade: emulateFacade,
      slotFound: mySlot() !== null,
      barSlots: barSlots().length,
      reorderGuard: reorderBlocked,
      reorderAreaEnabled: (function() { var a = reorderArea(mySlot()); return a ? a.enabled : null })(),
      integrated: integrated,
      luaConfig: hypr.luaConfig,
      version: hypr.version,
      altHeld: altHeld,
      hover: hoverAddress,
      popup: popup,
      available: Math.round(available),
      fitCount: fitCount,
      buttonExtent: buttonExtent,
      overflowing: overflowing,
      unavailable: unavailable,
      settings: config,
      windows: windows.map(function(t) {
        return {
          address: hexAddress(t),
          title: t.title || "",
          appId: appIdOf(t),
          icon: iconFor(t),
          minimized: isMinimized(t),
          active: !!t.activated,
          shown: shownWindows.indexOf(t) !== -1
        }
      })
    }
  }

  function sampleDropTargets() {
    var slot = workspacesSlot()
    if (!slot) return []
    var origin = slot.mapToItem(null, 0, 0)
    var seen = []
    var along = vertical ? slot.height : slot.width
    for (var p = 0; p < along; p += 2) {
      var point = vertical
        ? Qt.point(origin.x + slot.width / 2, origin.y + p)
        : Qt.point(origin.x + p, origin.y + slot.height / 2)
      var hit = workspaceAt(point)
      if (hit && (seen.length === 0 || seen[seen.length - 1].id !== hit.selector))
        seen.push({ id: hit.selector, at: Math.round(vertical ? hit.y : hit.x) })
    }
    return seen
  }

  // The instance on the focused monitor (Omarchy's summon picks the same).
  function focusedInstance() {
    var list = instances()
    var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < list.length; i++)
      if (list[i].screenRef && list[i].screenRef.name === focused) return list[i]
    return list.length > 0 ? list[0] : root
  }

  function instances() {
    return host && typeof host.moduleWidgets === "function" ? host.moduleWidgets(moduleName) : [root]
  }

  function instanceShowing(address) {
    var list = instances()
    var key = Logic.addressKey(address)
    for (var i = 0; i < list.length; i++) {
      var w = list[i].windows
      for (var j = 0; j < w.length; j++) if (list[i].keyOf(w[j]) === key) return { widget: list[i], toplevel: w[j] }
    }
    return null
  }

  // Only the first instance registers the target (it answers for every
  // monitor): with one handler per instance, Quickshell warns on every start
  // on multi-monitor setups. Re-evaluated as instances come and go.
  // A new instance isn't listed until the bar registers it, so "not listed"
  // means "not primary" (the listed one keeps the target meanwhile).
  // `bar` is injected after creation: until then nobody is primary (else every
  // instance would register for a moment). A host without moduleWidgets
  // (some replacement bars) can't list instances, so each is its own primary.
  readonly property bool ipcPrimary: {
    if (!host) return false
    if (typeof host.moduleWidgets !== "function") return true
    var list = host.moduleWidgets(moduleName)
    return list.length > 0 && list[0] === root
  }

  IpcHandler {
    target: "mourningazazel.taskbox"
    enabled: root.ipcPrimary

    // JSON snapshot of every instance (one per monitor).
    function state(): string {
      return JSON.stringify(root.instances().map(function(w) { return w.snapshot() }))
    }

    // Re-run the compatibility self-check; JSON list of unavailable features.
    function check(): string {
      var all = []
      root.instances().forEach(function(w) {
        w.checkCompat().forEach(function(m) { if (all.indexOf(m) === -1) all.push(m) })
      })
      return JSON.stringify(all)
    }

    // Hover highlight a window as if the pointer were on its button ("" clears).
    function hover(address: string): string {
      root.instances().forEach(function(w) { w.clearHover() })
      if (!address) return "cleared"
      var hit = root.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      hit.widget.setHover(hit.toplevel, true)
      return "ok"
    }

    // Left-click a window's button, as the user would (restore / minimize /
    // focus), on the taskbar of the monitor showing it.
    function click(address: string): string {
      var hit = root.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      hit.widget.activate(hit.toplevel)
      return "ok"
    }

    // Open a window's right-click menu.
    function menu(address: string): string {
      var hit = root.instanceShowing(address)
      if (!hit) return "not on a taskbar"
      hit.widget.openMenu(hit.widget.buttonFor(hit.toplevel), hit.toplevel)
      return "ok"
    }

    // Open the overflow list / settings on the focused monitor's taskbar (as
    // Omarchy's own summon does), or close any popup.
    function overflow(): string { var w = root.focusedInstance(); w.showPopup("overflow"); return w.popup }
    function settings(): string { var w = root.focusedInstance(); w.open(); return w.popup }
    function closePopups(): void { root.instances().forEach(function(w) { w.close() }) }

    // How an app id's icon is resolved (bypasses the cache).
    function icon(appId: string): string {
      var apps = DesktopEntries.applications.values
      var hosts = []
      for (var i = 0; i < apps.length; i++) {
        var h = Logic.urlHost(apps[i].execString)
        if (h) hosts.push(h)
      }
      var found = root.lookupIcon(appId, "")
      return JSON.stringify({
        appId: appId,
        webAppHost: Logic.webAppHost(appId),
        candidates: Logic.iconCandidates(appId, ""),
        desktopEntries: apps.length,
        webAppHosts: hosts,
        result: found
      })
    }

    // The workspace targets drag-and-drop would hit along each monitor's bar:
    // { "<screen>": [{ id, at }, …] }.
    function dropTargets(): string {
      var out = {}
      root.instances().forEach(function(w) { out[w.screenRef ? w.screenRef.name : "?"] = w.sampleDropTargets() })
      return JSON.stringify(out)
    }
  }
}
