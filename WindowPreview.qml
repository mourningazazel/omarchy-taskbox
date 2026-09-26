import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "lib/Logic.js" as Logic

// Hover thumbnail of a window, under its button (beside it on a vertical
// bar): a small card with a picture of the window, in place of the button's
// tooltip. The title is added only when the button doesn't show it
// (vertical bar, titles off, or a button too narrow for one). By default only for minimized windows (setting
// `preview`: minimized / all / off).
//
// The picture comes from grim, run as its own short-lived process (see the
// "previews" notes in lib/Logic.js): nothing GPU-specific happens in the
// shell, and if a capture fails the card shows the app icon instead.
// Captures start once the pointer has rested on a button for a moment, and a
// window is captured at most once per Logic.PREVIEW_REFRESH_MS.
Item {
  id: preview

  property var taskbar: null

  readonly property string mode: taskbar ? taskbar.config.preview : "off"
  readonly property int boxWidth: Logic.PREVIEW_WIDTH
  readonly property int boxMaxHeight: Logic.PREVIEW_MAX_HEIGHT
  readonly property string dir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/taskbox-preview"

  // The window being previewed and the button it hangs off.
  property var toplevel: null
  property Item anchorItem: null
  property bool shown: false
  readonly property string key: toplevel ? Logic.addressKey(toplevel.address) : ""
  // (eligible() again: a window restored under the pointer loses its preview.)
  readonly property bool visibleNow: shown && toplevel !== null && anchorItem !== null
    && taskbar !== null && taskbar.popup === "" && !taskbar.dragging && eligible(toplevel)

  // Last capture per window: key -> { time, ok, rev, ms }. Mutated in place
  // (read inside bindings); _rev is bumped from outside to refresh them.
  readonly property var _cache: ({})
  property int _rev: 0
  property int captures: 0          // diagnostics / tests
  property var _pending: null       // a window waiting for the running capture
  // Tests: make every capture fail (as if grim were missing), to check the
  // icon fallback. Set through the `previewFailure` IPC call only.
  property bool simulateFailure: false

  readonly property var entry: {
    var rev = _rev
    return key !== "" ? (_cache[key] || null) : null
  }

  function eligible(t) {
    return !!t && Logic.previewEligible(mode, taskbar.isMinimized(t))
  }

  // Called by TaskButton as the pointer rests on / leaves a button (not on
  // its ×, not while pressed or dragging). Returns whether a preview takes
  // the place of the tooltip.
  // (qmllint can't resolve Quickshell's PopupAnchor type: the window module's
  // qmltypes don't declare their dependency on core. Omarchy's own popups
  // use the same anchor API.)
  // qmllint disable unresolved-type missing-type
  function hover(button, t, on) {
    if (!on) {
      if (t === toplevel) hideTimer.restart()
      return false
    }
    if (!eligible(t)) {
      // Moving onto a button without a preview ends the current one.
      if (toplevel !== null) hide()
      return false
    }
    hideTimer.stop()
    var switching = shown && toplevel !== t
    toplevel = t
    anchorItem = button
    if (switching) {
      // Already showing one: follow the pointer without a new delay.
      capture(t)
      popup.anchor.updateAnchor()
    } else if (!shown) {
      captureTimer.restart()
      showTimer.restart()
    }
    return true
  }

  function hide() {
    captureTimer.stop()
    showTimer.stop()
    hideTimer.stop()
    shown = false
    toplevel = null
    anchorItem = null
    forgetClosed()
  }

  // Take a new picture unless the last one is recent enough.
  function capture(t) {
    if (!t) return
    var k = Logic.addressKey(t.address)
    if (!Logic.previewStale(_cache[k], Date.now())) return
    if (proc.running) { _pending = t; return }
    var win = popup.anchor.window
    var dpr = win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1
    proc.key = k
    proc.started = Date.now()
    proc.command = Logic.previewCaptureArgs(simulateFailure ? "0x0" : t.address, Logic.previewFile(dir, t.address),
      boxWidth * dpr, boxMaxHeight * dpr)
    proc.running = true
    captures++
  }

  // Drop pictures of windows that have closed.
  function forgetClosed() {
    var live = {}
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) live[Logic.addressKey(all[i].address)] = true
    var gone = []
    for (var k in _cache) {
      if (live[k]) continue
      delete _cache[k]
      gone.push(Logic.shellQuote(Logic.previewFile(dir, k)))
    }
    if (gone.length > 0 && taskbar.host) taskbar.host.run("rm -f " + gone.join(" "))
  }

  function snapshot() {
    return {
      mode: mode,
      target: toplevel ? Logic.hexAddress(toplevel.address) : "",
      shown: visibleNow,
      image: thumb.status === Image.Ready,
      captures: captures,
      capturing: proc.running,
      last: entry ? { ok: entry.ok, ms: entry.ms, ageMs: Date.now() - entry.time } : null,
      size: [Math.round(card.width), Math.round(card.height)],
      dpr: popup.anchor.window ? popup.anchor.window.devicePixelRatio : null
    }
  }

  onModeChanged: if (toplevel && !eligible(toplevel)) hide()
  Component.onDestruction: hide()

  // Only while the pointer rests: a sweep across the taskbar starts nothing.
  Timer { id: captureTimer; interval: 150; onTriggered: preview.capture(preview.toplevel) }
  Timer { id: showTimer; interval: 400; onTriggered: preview.shown = preview.toplevel !== null }
  // While the card stays up, keep it current, at the same once-per-3 s pace:
  // an app that changed while hidden redraws once it's captured, so the next
  // picture catches up.
  Timer {
    interval: Logic.PREVIEW_REFRESH_MS + 100   // just past the limit: never early
    repeat: true
    running: preview.visibleNow
    onTriggered: preview.capture(preview.toplevel)
  }
  // Grace for moving between buttons without the card flickering.
  Timer { id: hideTimer; interval: 150; onTriggered: preview.hide() }

  Process {
    id: proc
    property string key: ""
    property double started: 0
    // qmllint disable signal-handler-parameters
    onExited: function(exitCode, exitStatus) {
      // Aged from when it was requested, so the 3 s ticks below line up.
      preview._cache[key] = { time: started, ok: exitCode === 0, rev: preview._rev + 1, ms: Date.now() - started }
      if (exitCode !== 0) console.info("[taskbox] preview capture failed (" + exitCode + "); showing the app icon")
      preview._rev++
      var next = preview._pending
      preview._pending = null
      if (next && next === preview.toplevel) preview.capture(next)
    }
    // qmllint enable signal-handler-parameters
  }

  // The window or its workspace changed under the card (closed, restored,
  // moved): it no longer matches what's shown.
  Connections {
    target: preview.taskbar
    function onWindowsChanged() {
      if (preview.toplevel && preview.taskbar.windows.indexOf(preview.toplevel) === -1) preview.hide()
    }
  }

  PopupWindow {
    id: popup
    visible: preview.visibleNow
    color: "transparent"
    implicitWidth: Math.ceil(card.width)
    implicitHeight: Math.ceil(card.height)
    mask: Region {}   // never takes the pointer

    anchor {
      window: preview.taskbar ? preview.taskbar.QsWindow.window : null
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      // Like the bar's tooltips: centred below the button, above it on a
      // bottom bar, beside it on a vertical one.
      onAnchoring: {
        var target = preview.anchorItem
        var win = popup.anchor.window
        if (!target || !win || !win.contentItem) return
        var gap = Style.space(6)
        var w = popup.implicitWidth, h = popup.implicitHeight
        var position = preview.taskbar.host ? preview.taskbar.host.position : "top"
        var x = target.width / 2 - w / 2, y = target.height + gap
        if (position === "bottom") y = -h - gap
        else if (position === "left") { x = target.width + gap; y = target.height / 2 - h / 2 }
        else if (position === "right") { x = -w - gap; y = target.height / 2 - h / 2 }
        var point = win.contentItem.mapFromItem(target, x, y)
        popup.anchor.rect.x = Math.round(point.x)
        popup.anchor.rect.y = Math.round(point.y)
      }
    }

    Rectangle {
      id: card
      readonly property int pad: Style.space(4)
      // The window's shape, fitted to the box; before the first picture
      // arrives, its last known size from Hyprland.
      readonly property var box: {
        if (thumb.status === Image.Ready && thumb.implicitWidth > 0)
          return Logic.previewSize(thumb.implicitWidth, thumb.implicitHeight, preview.boxWidth, preview.boxMaxHeight)
        var ipc = preview.toplevel ? preview.toplevel.lastIpcObject : null
        var size = ipc && ipc.size ? ipc.size : null
        return Logic.previewSize(size ? size[0] : 0, size ? size[1] : 0, preview.boxWidth, preview.boxMaxHeight)
      }
      width: preview.boxWidth + pad * 2
      height: (title.visible ? title.height + Style.space(4) : 0) + box.height + pad * 2
      radius: Style.cornerRadius
      color: Color.tooltip.background
      border.width: 1
      border.color: Color.tooltip.border
      opacity: preview.visibleNow ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 100 } }

      Text {
        id: title
        visible: !!preview.anchorItem && preview.anchorItem.titleShown === false
        x: card.pad
        y: card.pad
        width: preview.boxWidth
        text: preview.toplevel ? (preview.toplevel.title || preview.taskbar.appIdOf(preview.toplevel) || "Window") : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Color.tooltip.text
        font.family: preview.taskbar ? preview.taskbar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        opacity: 0.85
      }

      Item {
        id: frame
        x: card.pad + (preview.boxWidth - width) / 2
        y: title.visible ? title.y + title.height + Style.space(4) : card.pad
        width: card.box.width
        height: card.box.height

        // Placeholder: the app icon, while the picture loads or if it can't be taken.
        Rectangle {
          anchors.fill: parent
          visible: thumb.status !== Image.Ready
          radius: Math.max(2, Style.cornerRadius / 2)
          color: Util.alpha(Color.tooltip.text, 0.06)
          Image {
            anchors.centerIn: parent
            width: Math.min(Style.space(32), parent.height * 0.6)
            height: width
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            source: preview.toplevel ? preview.taskbar.iconFor(preview.toplevel) : ""
            asynchronous: true
            opacity: 0.5
          }
        }

        Image {
          id: thumb
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          source: preview.entry && preview.entry.ok
            ? "file://" + Logic.previewFile(preview.dir, preview.key) + "?" + preview.entry.rev : ""
        }

        // Hairline outline, so a dark window stays distinct from the card.
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: Math.max(2, Style.cornerRadius / 2)
          border.width: 1
          border.color: Util.alpha(Color.tooltip.text, 0.18)
        }
      }
    }
  }
}
