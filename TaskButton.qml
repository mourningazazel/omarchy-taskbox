import QtQuick
import qs.Commons

// One taskbar button: [icon] [title……] [×] on a top/bottom bar, a centred
// icon on a left/right bar (the title is in the tooltip). Minimized windows
// are dimmed; right-click opens the window menu.
Item {
  id: button

  property var taskbar: null
  property var toplevel: null
  property bool inPopup: false

  readonly property bool compact: taskbar.vertical && !inPopup
  readonly property bool iconOnly: !taskbar.vertical && !taskbar.showTitle && !inPopup
  readonly property bool minimized: taskbar.isMinimized(toplevel)
  readonly property bool active: toplevel ? toplevel.activated && !minimized : false
  readonly property bool urgent: toplevel ? toplevel.urgent : false
  readonly property string title: toplevel ? (toplevel.title || taskbar.appIdOf(toplevel) || "Window") : ""
  readonly property bool hovered: mainMouse.containsMouse || closeMouse.containsMouse
  readonly property int pad: Style.space(6)
  readonly property int iconSize: Style.bar.iconCanvas
  readonly property int closeSize: Style.space(18)
  readonly property bool forceMode: taskbar.altHeld && closeMouse.containsMouse

  readonly property bool closeShown: {
    if (compact || taskbar.closeButton === "never") return false
    if (iconOnly) return width >= iconSize + closeSize + Style.space(6)
      && (taskbar.closeButton === "always" || hovered)
    if (taskbar.closeButton === "always") return width >= iconSize + closeSize + pad * 2
    return hovered
  }
  readonly property bool titleShown: inPopup
    || (!compact && taskbar.showTitle && width >= iconSize + closeSize + pad * 3 + Style.space(24))

  readonly property color markColor: urgent ? taskbar.urgentColor : taskbar.accent

  onHoveredChanged: taskbar.setHover(toplevel, hovered)

  // The window can close (or move away) under the pointer or mid-drag; don't
  // leave a tooltip, a hover highlight or a drag behind.
  Component.onDestruction: {
    if (hovered) {
      taskbar.setHover(toplevel, false)
      if (taskbar.host) {
        taskbar.host.hideTooltip(button)
        taskbar.host.hideTooltip(closeArea)
      }
    }
    if (mainMouse.dragged && mainMouse.dragMode === "window") taskbar.finishDrag(false)
  }

  Rectangle {
    id: bg
    anchors.fill: parent
    anchors.topMargin: button.inPopup || button.compact ? 0 : Style.space(3)
    anchors.bottomMargin: button.inPopup || button.compact ? 0 : Style.space(3)
    anchors.leftMargin: button.compact ? Style.space(3) : 0
    anchors.rightMargin: button.compact ? Style.space(3) : 0
    radius: Style.cornerRadius
    color: {
      var a = button.active ? 0.16 : (button.minimized ? 0.02 : 0.06)
      if (button.hovered) a += 0.08
      // The theme's foreground, or the custom highlight colour.
      return Util.alpha(taskbar.highlightBase, a)
    }

    Behavior on color { ColorAnimation { duration: 120 } }

    // Underline on a horizontal bar; a bar on the inner edge on a vertical one.
    Rectangle {
      visible: button.active || button.urgent
      anchors.left: parent.left
      anchors.right: button.compact ? undefined : parent.right
      anchors.top: button.compact ? parent.top : undefined
      anchors.bottom: parent.bottom
      width: Math.max(2, Style.space(2))
      height: Math.max(2, Style.space(2))
      color: button.markColor
    }
  }

  MouseArea {
    id: mainMouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: taskbar.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    // Keep the grab when the pointer leaves the button (and stop the bar's
    // own press-and-hold widget reordering from taking over).
    preventStealing: true

    property point pressPoint: Qt.point(0, 0)
    property point pressScene: Qt.point(0, 0)
    property bool dragged: false
    // "window": dragging this window onto a workspace number. (Alt+drag never
    // gets here: the taskbar lifts its reorder guard while Alt is held, so the
    // bar itself takes the press and moves the whole widget.)
    property string dragMode: ""

    onPressed: function(mouse) {
      pressPoint = Qt.point(mouse.x, mouse.y)
      pressScene = mapToItem(null, mouse.x, mouse.y)
      dragged = false
      dragMode = ""
    }

    onPositionChanged: function(mouse) {
      if (button.inPopup || !(mouse.buttons & Qt.LeftButton)) return
      var scene = mapToItem(null, mouse.x, mouse.y)
      if (!dragged) {
        if (Math.abs(mouse.x - pressPoint.x) + Math.abs(mouse.y - pressPoint.y) < Style.space(8)) return
        dragged = true
        if (taskbar.host) taskbar.host.hideTooltip(button)
        dragMode = taskbar.beginDrag(button.toplevel, scene) ? "window" : "none"   // none: no Hyprland integration
      } else if (dragMode === "window") {
        taskbar.updateDrag(scene)
      }
    }

    onReleased: function(mouse) {
      if (!dragged) return
      if (dragMode === "window") taskbar.finishDrag(true)
    }

    onCanceled: {
      if (dragged && dragMode === "window") taskbar.finishDrag(false)
      dragged = false
    }

    onClicked: function(mouse) {
      if (dragged) { dragged = false; return }
      if (mouse.button === Qt.RightButton) {
        if (taskbar.host) taskbar.host.hideTooltip(button)
        taskbar.openMenu(button, button.toplevel)
        return
      }
      if (mouse.button === Qt.MiddleButton) {
        if (taskbar.middleClickClose) taskbar.closeWindow(button.toplevel, false)
        return
      }
      taskbar.activate(button.toplevel)
      if (button.inPopup) taskbar.close()
    }
    onEntered: if (taskbar.bar && !button.inPopup) taskbar.host.showTooltip(button, button.minimized ? button.title + " (minimized)" : button.title)
    onExited: if (taskbar.host) taskbar.host.hideTooltip(button)
  }

  Image {
    id: icon
    anchors.left: parent.left
    anchors.leftMargin: button.iconOnly && button.closeShown ? Style.space(3)
      : !button.compact && (button.titleShown || button.closeShown) ? button.pad : (parent.width - width) / 2
    anchors.verticalCenter: parent.verticalCenter
    width: button.iconSize
    height: button.iconSize
    sourceSize.width: button.iconSize * 2
    sourceSize.height: button.iconSize * 2
    source: taskbar.iconFor(button.toplevel)
    asynchronous: true
    smooth: true
    opacity: button.minimized ? 0.45 : (button.active || button.hovered ? 1 : 0.8)
  }

  Text {
    anchors.left: icon.right
    anchors.leftMargin: button.pad
    anchors.right: closeArea.left
    anchors.rightMargin: Style.space(2)
    anchors.verticalCenter: parent.verticalCenter
    visible: button.titleShown
    text: button.title
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: taskbar.fg
    font.family: taskbar.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.italic: button.minimized
    opacity: button.minimized ? 0.5 : (button.active ? 1 : 0.8)
  }

  Item {
    id: closeArea
    anchors.right: parent.right
    anchors.rightMargin: Style.space(3)
    anchors.verticalCenter: parent.verticalCenter
    width: button.closeShown ? button.closeSize : 0
    height: button.closeSize

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      visible: closeMouse.containsMouse
      color: button.forceMode ? taskbar.urgentColor : Util.alpha(taskbar.fg, 0.18)
    }

    Text {
      anchors.centerIn: parent
      visible: button.closeShown
      text: "󰅖" // nf-md-close
      color: button.forceMode ? Color.background : taskbar.fg
      font.family: taskbar.fontFamily
      font.pixelSize: Style.font.body
      opacity: closeMouse.containsMouse ? 1 : 0.7
    }

    MouseArea {
      id: closeMouse
      anchors.fill: parent
      enabled: button.closeShown
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      // Force kill vs close is decided from the real Alt key state
      // (Taskbox.closeFromButton); altHeld only colours the × red.
      onClicked: taskbar.closeFromButton(button.toplevel)
      onEntered: if (taskbar.bar && !button.inPopup) taskbar.host.showTooltip(closeArea, taskbar.altHeld ? "Force kill" : "Close (Alt+click: force kill)")
      onExited: if (taskbar.host) taskbar.host.hideTooltip(closeArea)
    }
  }
}
