import QtQuick
import qs.Commons
import qs.Ui
import "lib/Logic.js" as Logic

// Taskbox settings, built from the shell's own controls. Opened from a
// button's right-click menu, by right-clicking "+N", or with
//   omarchy-shell shell toggle mourningazazel.taskbox
// Every change is written straight to shell.json via `omarchy bar set`.
// A KeyboardPanel, not a PopupCard: Omarchy's layer-shell panel that takes
// keyboard focus when it opens (xdg popups like PopupCard only get keys after
// a click routes focus through the bar), so Esc and typing into the fields
// work, and a click anywhere outside dismisses it.
KeyboardPanel {
  id: popup
  focusTarget: escapeCatcher

  property var taskbar: null

  bar: taskbar ? taskbar.host : null
  owner: taskbar ? taskbar.popupOwner : null
  contentWidth: popup.fittedContentWidth(Style.space(340))
  contentHeight: popup.fittedContentHeight(column.implicitHeight)

  readonly property color fg: taskbar ? taskbar.fg : Color.foreground
  readonly property string fontFamily: taskbar ? taskbar.fontFamily : Style.font.family

  // Number fields fire on every step and the colour picker on every drag
  // move; write once the value settles.
  property var pending: ({})
  // Highlight colour: preview on the taskbar at once, write once it settles.
  function setHighlight(hex) {
    taskbar.previewHighlight = hex
    if (hexField.text !== hex && !hexField.activeFocus) hexField.text = hex
    saveLater("highlightColor", hex)
  }

  onOpenChanged: if (open) hexField.text = taskbar.effectiveHighlight

  // Esc steps out one level: leave the hex field, then close the colour
  // picker, then close the settings popup.
  function stepOut() {
    if (hexField.activeFocus) escapeCatcher.forceActiveFocus()
    else if (taskbar.pickerOpen) taskbar.pickerOpen = false
    else taskbar.close()
  }

  function saveLater(key, value) {
    var next = {}
    for (var k in pending) next[k] = pending[k]
    next[key] = value
    pending = next
    pendingWrite.restart()
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

  // Receives keys when nothing else in the popup has focus (outside the
  // Column so it doesn't add a spacing gap).
  Item {
    id: escapeCatcher
    width: 0
    height: 0
    focus: true
    Keys.onEscapePressed: popup.stepOut()
  }

  Column {
    id: column
    width: popup.contentWidth - popup.padding * 2
    spacing: Style.space(4)


    // Lives in the Column: the panel's content slot only takes Items.
    Timer {
      id: pendingWrite
      interval: 400
      onTriggered: {
        for (var key in popup.pending) popup.taskbar.saveSetting(key, popup.pending[key])
        popup.pending = {}
      }
    }

    // Header: title + close button (Omarchy's panel action button). Esc
    // closes too — see the key handler below.
    Item {
      width: column.width
      height: Math.max(titleText.implicitHeight, closeButton.size) + Style.space(4)

      Text {
        id: titleText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Taskbox"
        color: popup.fg
        font.family: popup.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      PanelActionButton {
        id: closeButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "\uDB80\uDD56" // nf-md-close
        tooltipText: "Close (Esc)"
        foreground: popup.fg
        fontFamily: popup.fontFamily
        onClicked: popup.taskbar.close()
      }
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
      onModified: function(v) { popup.saveLater("maxWidth", v) }
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
      onModified: function(v) { popup.saveLater("minWidth", v) }
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
    ChoiceRow {
      label: "Hover previews"
      options: ["minimized", "all", "off"]
      value: popup.taskbar.previewMode
      onChosen: function(v) { popup.taskbar.saveSetting("preview", v) }
    }

    // Custom highlight colour: hex entry + a button opening the colour picker.
    Item {
      width: column.width
      height: Style.space(34)
      Label { text: "Custom highlight color"; anchors.left: parent.left }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        TextField {
          id: hexField
          width: Style.space(100)
          placeholderText: "theme"
          foreground: popup.fg
          accent: popup.taskbar.accent
          font.family: popup.fontFamily
          font.pixelSize: Style.font.bodySmall
          validator: RegularExpressionValidator { regularExpression: /#?[0-9a-fA-F]{0,6}/ }
          readonly property bool bad: text !== "" && Logic.parseHexColor(text) === ""
          color: bad ? popup.taskbar.urgentColor : popup.fg
          onTextEdited: {
            var hex = Logic.parseHexColor(text)
            if (hex !== "" || text === "") popup.setHighlight(hex)
          }
          onEditingFinished: if (bad) text = popup.taskbar.effectiveHighlight
          Keys.onEscapePressed: popup.stepOut()
        }

        // Opens the colour picker card below.
        Rectangle {
          id: wheelButton
          width: Style.space(30)
          height: Style.space(30)
          anchors.verticalCenter: parent.verticalCenter
          radius: Style.cornerRadius
          color: popup.taskbar.pickerOpen || wheelMouse.containsMouse ? Util.alpha(popup.fg, 0.14) : Util.alpha(popup.fg, 0.05)
          border.width: 1
          border.color: Util.alpha(popup.fg, 0.25)
          Text {
            anchors.centerIn: parent
            text: "\uDB80\uDFD8" // nf-md-palette
            color: popup.taskbar.effectiveHighlight !== "" ? popup.taskbar.effectiveHighlight : popup.fg
            font.family: popup.fontFamily
            font.pixelSize: Style.font.body + 2
          }
          MouseArea {
            id: wheelMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popup.taskbar.pickerOpen = !popup.taskbar.pickerOpen
          }
        }
      }
    }

    ColorPicker {
      visible: popup.taskbar.pickerOpen
      width: column.width
      height: visible ? implicitHeight : 0
      taskbar: popup.taskbar
      value: popup.taskbar.effectiveHighlight
      suggestions: popup.taskbar.highlightSuggestions
      pointerX: column.width - Style.space(15)
      onPicked: function(hex) { popup.setHighlight(hex) }
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
