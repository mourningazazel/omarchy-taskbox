import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "lib/Logic.js" as Logic

// Right-click menu for one taskbar button. Actions that need the Hyprland
// side (everything except Close) are hidden when it isn't available.
PopupCard {
  id: menu

  property var taskbar: null
  property var toplevel: null

  bar: taskbar ? taskbar.host : null
  owner: taskbar ? taskbar.popupOwner : null
  contentWidth: menu.fittedContentWidth(Style.space(240))
  contentHeight: menu.fittedContentHeight(column.implicitHeight)

  readonly property bool integrated: taskbar ? taskbar.integrated : false
  readonly property bool minimized: taskbar ? taskbar.isMinimized(toplevel) : false
  readonly property int currentWorkspace: toplevel && toplevel.workspace ? toplevel.workspace.id : 0
  readonly property color fg: taskbar ? taskbar.fg : Color.foreground

  // 1-10 always, plus any other regular workspace that currently exists.
  readonly property var workspaceIds:
    Logic.workspaceChoices(Hyprland.workspaces.values.map(function(w) { return w.id }))

  // Close the menu first, then act on the window it was opened for.
  function run(action) {
    var t = toplevel
    taskbar.close()
    if (t) action(t)
  }

  component MenuItem: Item {
    id: item
    property string glyph: ""
    property string label: ""
    property bool danger: false
    signal triggered()

    width: column.width
    height: Style.space(28)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: itemMouse.containsMouse
        ? Util.alpha(item.danger ? menu.taskbar.urgentColor : menu.fg, item.danger ? 0.28 : 0.12)
        : "transparent"
    }
    Text {
      id: glyphText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      text: item.glyph
      color: item.danger ? menu.taskbar.urgentColor : menu.fg
      font.family: menu.taskbar.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      anchors.left: glyphText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: item.label
      elide: Text.ElideRight
      color: item.danger ? menu.taskbar.urgentColor : menu.fg
      font.family: menu.taskbar.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: itemMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: item.triggered()
    }
  }

  component Separator: Rectangle {
    width: column.width
    height: 1
    color: Util.alpha(menu.fg, 0.12)
  }

  Column {
    id: column
    width: menu.contentWidth - menu.padding * 2
    spacing: Style.space(2)

    Text {
      width: parent.width
      bottomPadding: Style.space(4)
      text: menu.toplevel ? (menu.toplevel.title || menu.taskbar.appIdOf(menu.toplevel)) : ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: menu.fg
      opacity: 0.7
      font.family: menu.taskbar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MenuItem {
      visible: menu.integrated
      glyph: menu.minimized ? "󰖲" : "󰖰" // window-restore / window-minimize
      label: menu.minimized ? "Restore" : "Minimize"
      onTriggered: menu.run(function(t) {
        if (menu.minimized) menu.taskbar.restoreWindow(t)
        else menu.taskbar.minimizeWindow(t)
      })
    }
    MenuItem {
      visible: menu.integrated && !menu.minimized
      glyph: "󰖯" // window-maximize
      label: "Maximize / restore size"
      onTriggered: menu.run(function(t) { menu.taskbar.toggleMaximized(t) })
    }
    MenuItem {
      visible: menu.integrated && !menu.minimized
      glyph: "󰀽" // arrange-bring-forward
      label: "Float / tile"
      onTriggered: menu.run(function(t) { menu.taskbar.toggleFloating(t) })
    }

    Text {
      visible: menu.integrated
      topPadding: Style.space(6)
      bottomPadding: Style.space(2)
      leftPadding: Style.space(8)
      text: "Move to workspace"
      color: menu.fg
      opacity: 0.6
      font.family: menu.taskbar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Flow {
      id: chips
      visible: menu.integrated
      leftPadding: Style.space(6)
      spacing: Style.space(3)
      bottomPadding: Style.space(4)
      width: column.width
      // Ten per row, whatever the menu width; extra workspaces wrap below.
      readonly property real chipWidth: Math.floor((column.width - leftPadding - spacing * 9) / 10)

      Repeater {
        model: menu.workspaceIds

        Rectangle {
          required property var modelData
          readonly property int workspaceId: modelData
          readonly property bool current: workspaceId === menu.currentWorkspace

          width: chips.chipWidth
          height: Style.space(22)
          radius: Style.cornerRadius
          color: current ? Util.alpha(menu.taskbar.accent, 0.35)
            : Util.alpha(menu.fg, chipMouse.containsMouse ? 0.18 : 0.06)

          Text {
            anchors.centerIn: parent
            text: Logic.workspaceLabel(parent.workspaceId)
            color: menu.fg
            font.family: menu.taskbar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !parent.current
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var id = parent.workspaceId
              menu.run(function(t) { menu.taskbar.sendToWorkspace(t, id) })
            }
          }
        }
      }
    }

    Separator {}

    MenuItem {
      glyph: "󰅖" // close
      label: "Close"
      onTriggered: menu.run(function(t) { menu.taskbar.closeWindow(t, false) })
    }
    MenuItem {
      visible: menu.integrated
      danger: true
      glyph: "󰚌" // skull
      label: "Force kill app"
      onTriggered: menu.run(function(t) { menu.taskbar.closeWindow(t, true) })
    }

    Separator {}

    MenuItem {
      glyph: "󰒓" // cog
      label: "Taskbox settings…"
      onTriggered: { menu.taskbar.close(); menu.taskbar.open() }
    }
  }
}
