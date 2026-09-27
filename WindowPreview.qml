import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "lib/Logic.js" as Logic

// Hover thumbnail of a window, under its button (beside it on a vertical
// bar), in place of the button's tooltip. By default only for minimized
// windows (setting `preview`: minimized / all / off). The card shows the
// title too when the button can't show all of it.
//
// The picture comes from grim, run as its own short-lived process (see
// "previews" in lib/Logic.js): nothing GPU-specific happens in the shell, and
// if a capture fails the card shows the app icon instead.
//
// Timing: capture after the pointer has rested 150 ms, reveal the card at
// 400 ms once its picture is in (or after 1 s with the icon), hide 150 ms
// after the pointer leaves. A window is captured at most once per
// Logic.PREVIEW_REFRESH_MS, also while the card stays up.
//
// (qmllint can't resolve Quickshell's PopupAnchor type — the window module's
// qmltypes don't declare their dependency on core — hence the disable below.
// Omarchy's own popups use the same anchor API.)
// qmllint disable unresolved-type missing-type
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
  readonly property string key: toplevel ? Logic.addressKey(toplevel.address) : ""
  property bool shown: false        // the hover delay has passed
  property bool waitedOut: false    // …and so has the wait for a picture

  // The picture for this window is in, or isn't coming (failed capture).
  readonly property bool pictureSettled: thumbs.frontKey === key
    || (entry !== null && !entry.ok && !proc.running)
  // (eligible() again: a window restored under the pointer loses its card.)
  readonly property bool visibleNow: shown && (pictureSettled || waitedOut)
    && toplevel !== null && anchorItem !== null && taskbar !== null
    && taskbar.popup === "" && !taskbar.dragging && eligible(toplevel)

  // Last capture per window: key -> { time, ok, rev, ms }. Mutated in place
  // (read inside bindings); _rev is bumped from outside to refresh them.
  readonly property var _cache: ({})
  property int _rev: 0
  property int captures: 0          // diagnostics / tests
  property var _pending: null       // a window waiting for the running capture
  // When each window last opened / moved / changed floating (key -> ms).
  readonly property var _changed: ({})
  // Actions waiting for a capture of their window to finish (see afterCapture).
  property var _afterCapture: []
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
      waitTimer.restart()
    }
    return true
  }

  function hide() {
    captureTimer.stop()
    showTimer.stop()
    waitTimer.stop()
    hideTimer.stop()
    settleTimer.stop()
    shown = false
    waitedOut = false
    toplevel = null
    anchorItem = null
    forgetClosed()
  }

  // Take a new picture unless the last one is recent enough, or the window
  // is still settling after a move (then try again once it has).
  function capture(t) {
    if (!t) return
    var k = Logic.addressKey(t.address)
    if (!Logic.previewStale(_cache[k], Date.now())) return
    var wait = Logic.previewSettleDelay(_changed[k], Date.now())
    if (wait > 0) { settleTimer.interval = wait; settleTimer.restart(); return }
    if (proc.running) { _pending = t; return }
    var win = popup.anchor.window
    var dpr = win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1
    proc.key = k
    proc.started = Date.now()
    proc.command = Logic.previewCaptureArgs(simulateFailure ? "0x0" : t.address,
      Logic.previewFile(dir, t.address), boxWidth * dpr, boxMaxHeight * dpr)
    proc.running = true
    captures++
  }

  // Run fn now, or once a running capture of window t has finished (at most
  // ~1 s): closing a window mid-capture makes grim 1.5.0 crash.
  function afterCapture(t, fn) {
    if (!t || !proc.running || proc.key !== Logic.addressKey(t.address)) { fn(); return }
    var queue = _afterCapture.slice()
    queue.push(fn)
    _afterCapture = queue
    afterCaptureLimit.restart()
  }

  function _flushAfterCapture() {
    afterCaptureLimit.stop()
    var queue = _afterCapture
    _afterCapture = []
    for (var i = 0; i < queue.length; i++) queue[i]()
  }

  // Drop pictures of windows that have closed: their cache entries, any
  // image still holding one (addresses are reused, and a held image would
  // re-read a deleted file), then the files.
  function forgetClosed() {
    var live = {}
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) live[Logic.addressKey(all[i].address)] = true
    var gone = []
    for (var k in _cache) {
      if (live[k]) continue
      delete _cache[k]
      thumbs.forget(k)
      gone.push(Logic.shellQuote(Logic.previewFile(dir, k)))
    }
    for (var c in _changed) if (!live[c]) delete _changed[c]
    if (gone.length > 0 && taskbar.host) taskbar.host.run("rm -f " + gone.join(" "))
  }

  function snapshot() {
    return {
      mode: mode,
      target: toplevel ? Logic.hexAddress(toplevel.address) : "",
      shown: visibleNow,
      image: thumbs.frontKey !== "" && thumbs.frontKey === key,
      captures: captures,
      capturing: proc.running,
      last: entry ? { ok: entry.ok, ms: entry.ms, ageMs: Date.now() - entry.time } : null,
      size: [Math.round(card.width), Math.round(card.height)],
      dpr: popup.anchor.window ? popup.anchor.window.devicePixelRatio : null
    }
  }

  onModeChanged: if (toplevel && !eligible(toplevel)) hide()
  Component.onDestruction: { hide(); _flushAfterCapture() }

  // Only while the pointer rests: a sweep across the taskbar starts nothing.
  Timer { id: captureTimer; interval: 150; onTriggered: preview.capture(preview.toplevel) }
  Timer { id: showTimer; interval: 400; onTriggered: preview.shown = preview.toplevel !== null }
  Timer { id: waitTimer; interval: 1000; onTriggered: preview.waitedOut = preview.toplevel !== null }
  Timer { id: settleTimer; onTriggered: preview.capture(preview.toplevel) }
  // Grace for moving between buttons without the card flickering.
  Timer { id: hideTimer; interval: 150; onTriggered: preview.hide() }
  // grim is given 3 s; don't hold a close back for longer than a moment.
  Timer { id: afterCaptureLimit; interval: 1000; onTriggered: preview._flushAfterCapture() }
  // While the card stays up, keep it current, at the same once-per-3 s pace:
  // an app that changed while hidden redraws once it's captured, so the next
  // picture catches up.
  Timer {
    interval: Logic.PREVIEW_REFRESH_MS + 100   // just past the limit: never early
    repeat: true
    running: preview.visibleNow
    onTriggered: preview.capture(preview.toplevel)
  }

  Process {
    id: proc
    property string key: ""
    property double started: 0
    // qmllint disable signal-handler-parameters
    onExited: function(exitCode, exitStatus) {
      // Aged from when it was requested, so the 3 s ticks line up.
      preview._cache[key] = { time: started, ok: exitCode === 0, rev: preview._rev + 1, ms: Date.now() - started }
      if (exitCode !== 0)
        console.info("[taskbox] preview capture: " + (Logic.PREVIEW_EXIT[exitCode] || "exit " + exitCode) + "; showing the app icon")
      preview._rev++
      preview._flushAfterCapture()
      var next = preview._pending
      preview._pending = null
      if (next && next === preview.toplevel) preview.capture(next)
    }
    // qmllint enable signal-handler-parameters
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var k = Logic.changedWindowOf(event.name, event.data)
      if (k) preview._changed[k] = Date.now()
    }
  }

  // The window or its workspace changed under the card (closed, restored,
  // moved): it no longer matches what's shown.
  Connections {
    target: preview.taskbar
    function onWindowsChanged() {
      if (preview.toplevel && preview.taskbar.windows.indexOf(preview.toplevel) === -1) preview.hide()
      else preview.forgetClosed()
    }
  }

  PopupWindow {
    id: popup
    visible: preview.visibleNow
    color: "transparent"
    implicitWidth: Math.ceil(card.width)
    implicitHeight: Math.ceil(card.height)
    mask: Region {}   // never takes the pointer
    // Above a bottom bar / left of a right bar the card hangs from its far
    // edge, so a new size needs a new position.
    onImplicitHeightChanged: if (visible) anchor.updateAnchor()

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
      // The window's shape fitted to the box: from its picture, or before
      // that from its last known size in Hyprland.
      readonly property var box: {
        if (thumbs.frontKey === preview.key && thumbs.front.implicitWidth > 0)
          return Logic.previewSize(thumbs.front.implicitWidth, thumbs.front.implicitHeight, preview.boxWidth, preview.boxMaxHeight)
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
        visible: !!preview.anchorItem && preview.anchorItem.titleFullyVisible === false
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

        // Placeholder: the app icon, until this window's picture is in, or
        // if it can't be taken.
        Rectangle {
          anchors.fill: parent
          visible: thumbs.frontKey !== preview.key
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

        // Two images, double-buffered: a new picture loads into the hidden
        // one and is swapped in once decoded, so a refresh never blinks.
        Item {
          id: thumbs
          anchors.fill: parent
          readonly property string url: preview.entry && preview.entry.ok
            ? "file://" + Logic.previewFile(preview.dir, preview.key) + "?" + preview.entry.rev : ""
          property int frontIndex: 0
          readonly property Image front: frontIndex === 0 ? thumbA : thumbB
          readonly property Image back: frontIndex === 0 ? thumbB : thumbA
          // Whose picture has been decoded into the front image. Latched when
          // it's swapped in, not read from the image's status: an image
          // reloads (briefly "Loading") when the popup window first appears.
          property string readyKey: ""
          readonly property string frontKey: front.forKey === readyKey ? readyKey : ""

          function forget(k) {
            for (var i = 0; i < 2; i++) {
              var img = i === 0 ? thumbA : thumbB
              if (img.forKey === k) { img.source = ""; img.forKey = "" }
            }
            if (readyKey === k) readyKey = ""
          }

          onUrlChanged: {
            if (url === "") return
            // Already decoded in one of the two (switching back to a window
            // within its reuse window): no new load, so no Ready to wait for.
            if (String(front.source) === url && front.status === Image.Ready) { readyKey = front.forKey; return }
            if (String(back.source) === url && back.status === Image.Ready) {
              frontIndex = frontIndex === 0 ? 1 : 0
              readyKey = front.forKey
              return
            }
            back.forKey = preview.key
            back.source = url
          }

          component Thumb: Image {
            id: self
            property string forKey: ""
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            // Each picture has its own URL (?rev), so the pixmap cache never
            // serves a stale one, and a reload doesn't go back to the disk.
            cache: true
            smooth: true
            mipmap: true
            onStatusChanged: {
              if (status === Image.Ready && self === thumbs.back) {
                thumbs.frontIndex = thumbs.frontIndex === 0 ? 1 : 0
                thumbs.readyKey = self.forKey
              }
            }
          }
          Thumb { id: thumbA; visible: thumbs.frontIndex === 0 && forKey === preview.key }
          Thumb { id: thumbB; visible: thumbs.frontIndex === 1 && forKey === preview.key }
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
