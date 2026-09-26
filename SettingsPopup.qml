import QtQuick
import qs.Commons
import qs.Ui

// Taskbox settings, built from the shell's own controls. Opened from a
// button's right-click menu, by right-clicking "+N", or with
//   omarchy-shell shell toggle mourningazazel.taskbox
// Every change is written straight to shell.json via `omarchy bar set`.
PopupCard {
  id: popup

  property var taskbar: null

  bar: taskbar ? taskbar.host : null
  owner: taskbar ? taskbar.popupOwner : null
  contentWidth: popup.fittedContentWidth(Style.space(340))
  contentHeight: popup.fittedContentHeight(column.implicitHeight)

  readonly property color fg: taskbar ? taskbar.fg : Color.foreground
  readonly property string fontFamily: taskbar ? taskbar.fontFamily : Style.font.family

  // Number fields fire on every step; write once the value settles.
  property var pending: ({})
  function saveNumber(key, value) {
    var next = {}
    for (var k in pending) next[k] = pending[k]
    next[key] = value
    pending = next
    numberWrite.restart()
  }

  component Label: Text {
    color: popup.fg
    font.family: popup.fontFamily
    font.pixelSize: Style.font.body
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
  }

  component SwitchRow: Item {
    id: row
    property string label: ""
    property bool checked: false
    signal toggled()
    width: column.width
    height: Style.space(30)
    Label { text: row.label; anchors.left: parent.left }
    ToggleSwitch {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: row.checked
      foreground: popup.fg
      accent: popup.taskbar.accent
      onToggled: row.toggled()
    }
  }

  component ChoiceRow: Item {
    id: choice
    property string label: ""
    property var options: []
    property string value: ""
    signal chosen(string value)
    width: column.width
    height: Style.space(34)
    Label { text: choice.label; anchors.left: parent.left }
    ButtonGroup {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: choice.options
      value: choice.value
      foreground: popup.fg
      accent: popup.taskbar.accent
      fontFamily: popup.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { choice.chosen(v) }
    }
  }

  Column {
    id: column
    width: popup.contentWidth - popup.padding * 2
    spacing: Style.space(4)

    // Lives in the Column: PopupCard's content slot only takes Items.
    Timer {
      id: numberWrite
      interval: 400
      onTriggered: {
        for (var key in popup.pending) popup.taskbar.saveSetting(key, popup.pending[key])
        popup.pending = {}
      }
    }

    Text {
      text: "Taskbox"
      color: popup.fg
      font.family: popup.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      bottomPadding: Style.space(4)
    }

    NumberField {
      width: column.width
      label: "Title button width (px)"
      from: 60
      to: 600
      stepSize: 10
      value: popup.taskbar.maxWidth
      foreground: popup.fg
      accent: popup.taskbar.accent
      fontFamily: popup.fontFamily
      onModified: function(v) { popup.saveNumber("maxWidth", v) }
    }
    NumberField {
      width: column.width
      label: "Minimum / icon-only width (px)"
      from: 24
      to: 300
      stepSize: 4
      value: popup.taskbar.minWidth
      foreground: popup.fg
      accent: popup.taskbar.accent
      fontFamily: popup.fontFamily
      onModified: function(v) { popup.saveNumber("minWidth", v) }
    }

    SwitchRow {
      label: "Window titles"
      checked: popup.taskbar.showTitle
      onToggled: popup.taskbar.saveSetting("showTitle", !popup.taskbar.showTitle)
    }
    ChoiceRow {
      label: "Close button"
      options: ["hover", "always", "never"]
      value: popup.taskbar.closeButton
      onChosen: function(v) { popup.taskbar.saveSetting("closeButton", v) }
    }
    SwitchRow {
      label: "Middle-click closes"
      checked: popup.taskbar.middleClickClose
      onToggled: popup.taskbar.saveSetting("middleClickClose", !popup.taskbar.middleClickClose)
    }
    SwitchRow {
      label: "Click focused window to minimize"
      checked: popup.taskbar.clickToMinimize
      onToggled: popup.taskbar.saveSetting("clickToMinimize", !popup.taskbar.clickToMinimize)
    }
    SwitchRow {
      label: "Show minimized windows"
      checked: popup.taskbar.showMinimized
      onToggled: popup.taskbar.saveSetting("showMinimized", !popup.taskbar.showMinimized)
    }

    Rectangle { width: column.width; height: 1; color: Util.alpha(popup.fg, 0.12) }

    Text {
      width: column.width
      topPadding: Style.space(4)
      wrapMode: Text.WordWrap
      color: popup.fg
      opacity: 0.6
      font.family: popup.fontFamily
      font.pixelSize: Style.font.bodySmall
      text: "Drag a button onto a workspace number to send it there · Alt+× force-kills · Alt+drag moves the taskbar · Right-click a button for more"
    }

    // Only shown when the self-check found something missing.
    Text {
      visible: popup.taskbar.unavailable.length > 0
      width: column.width
      wrapMode: Text.WordWrap
      color: popup.taskbar.urgentColor
      font.family: popup.fontFamily
      font.pixelSize: Style.font.bodySmall
      text: "Unavailable on this setup: " + popup.taskbar.unavailable.join(" · ")
    }
  }
}
