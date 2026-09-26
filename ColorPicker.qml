import QtQuick
import qs.Commons
import "lib/Logic.js" as Logic

// Colour popover for the custom highlight: a hue/saturation wheel, a
// brightness slider, a preview, and five suggested colours (harmonies of the
// theme accent, from the taskbar). Shown inside the settings popup, under the
// row it belongs to, with a pointer to the button that opened it.
//
// It's a card in the settings popup's own window rather than a second popup:
// a nested PopupCard would start its own focus grab, which cancels the
// settings popup's grab and closes it.
Item {
  id: picker

  property var taskbar: null
  property string value: ""              // "#rrggbb", or "" = theme default
  property var suggestions: []
  property real pointerX: width - Style.space(18)   // where the arrow points

  signal picked(string hex)               // "" = back to the theme default

  readonly property color fg: taskbar ? taskbar.fg : Color.foreground
  readonly property string fontFamily: taskbar ? taskbar.fontFamily : Style.font.family
  readonly property int pad: Style.space(10)
  readonly property int wheelSize: Style.space(132)
  readonly property int arrow: Style.space(7)

  // HSV state behind the wheel and slider.
  property real hue: 0
  property real sat: 0
  property real val: 1
  readonly property string current: Logic.hsvToHex(hue, sat, val)

  function syncFrom(hex) {
    var rgb = Logic.hexToRgb(hex) || Logic.hexToRgb(taskbar ? taskbar.colorHex(taskbar.fg) : "#cacccc")
    var hsv = Logic.rgbToHsv(rgb)
    hue = hsv.h
    sat = hsv.s
    val = hsv.v
    wheel.requestPaint()
  }

  function choose() { picked(current) }

  onVisibleChanged: if (visible) syncFrom(value)
  onValChanged: wheel.requestPaint()

  implicitHeight: arrow + card.implicitHeight

  // Arrow pointing up at the wheel button.
  Rectangle {
    x: picker.pointerX - width / 2
    y: picker.arrow / 2 + 1
    width: picker.arrow * 1.6
    height: width
    rotation: 45
    color: card.color
    border.width: 1
    border.color: card.border.color
    z: 0
  }

  Rectangle {
    id: card
    y: picker.arrow
    width: parent.width
    implicitHeight: body.implicitHeight + picker.pad * 2
    radius: Style.cornerRadius
    color: Qt.tint(Color.popups.background, Util.alpha(picker.fg, 0.06))
    border.width: 1
    border.color: Util.alpha(picker.fg, 0.2)
    z: 1

    // Cover the arrow's lower half so it reads as part of the card.
    Rectangle {
      x: picker.pointerX - width / 2
      y: 1
      width: picker.arrow * 2.4
      height: picker.arrow
      color: card.color
    }

    Column {
      id: body
      x: picker.pad
      y: picker.pad
      width: parent.width - picker.pad * 2
      spacing: Style.space(10)

      Row {
        spacing: Style.space(14)

        // Hue around the wheel, saturation outward; brightness darkens it.
        Canvas {
          id: wheel
          width: picker.wheelSize
          height: picker.wheelSize
          antialiasing: true

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var c = width / 2, r = width / 2 - 1
            // One conical gradient for the hue ring (thin pie slices leave
            // visible seams near the centre). Qt's conical gradient runs
            // counter-clockwise, so hues are laid in reverse to put hue θ at
            // screen angle θ (clockwise, 0 = right) — the same angle the
            // marker and the mouse use.
            var ring = ctx.createConicalGradient(c, c, 0)
            for (var i = 0; i <= 12; i++) ring.addColorStop(i / 12, Qt.hsva(((12 - i) % 12) / 12, 1, 1, 1))
            ctx.beginPath()
            ctx.arc(c, c, r, 0, 2 * Math.PI)
            ctx.fillStyle = ring
            ctx.fill()
            var white = ctx.createRadialGradient(c, c, 0, c, c, r)
            white.addColorStop(0, "white")
            white.addColorStop(1, Qt.rgba(1, 1, 1, 0))
            ctx.beginPath()
            ctx.arc(c, c, r, 0, 2 * Math.PI)
            ctx.fillStyle = white
            ctx.fill()
            ctx.fillStyle = Qt.rgba(0, 0, 0, 1 - picker.val)
            ctx.fill()
          }

          // Marker at the current hue/saturation.
          Rectangle {
            readonly property real r: wheel.width / 2 - 1
            width: Style.space(12)
            height: width
            radius: width / 2
            x: wheel.width / 2 + Math.cos(picker.hue * Math.PI / 180) * picker.sat * r - width / 2
            y: wheel.height / 2 + Math.sin(picker.hue * Math.PI / 180) * picker.sat * r - height / 2
            color: picker.current
            border.width: 2
            border.color: picker.val > 0.55 ? "#000000" : "#ffffff"
          }

          MouseArea {
            anchors.fill: parent
            preventStealing: true
            cursorShape: Qt.CrossCursor
            function pick(mouse) {
              var c = wheel.width / 2
              var dx = mouse.x - c, dy = mouse.y - c
              var deg = Math.atan2(dy, dx) * 180 / Math.PI
              picker.hue = deg < 0 ? deg + 360 : deg
              picker.sat = Math.min(1, Math.sqrt(dx * dx + dy * dy) / (c - 1))
              picker.choose()
            }
            onPressed: function(mouse) { pick(mouse) }
            onPositionChanged: function(mouse) { if (pressed) pick(mouse) }
          }
        }

        Column {
          spacing: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            width: Style.space(76)
            height: Style.space(40)
            radius: Style.cornerRadius
            color: picker.value === "" ? Util.alpha(picker.fg, 0.16) : picker.current
            border.width: 1
            border.color: Util.alpha(picker.fg, 0.25)
          }
          Text {
            text: picker.value === "" ? "theme" : picker.current
            color: picker.fg
            font.family: picker.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            text: "Theme default"
            visible: picker.value !== ""
            color: picker.fg
            opacity: resetMouse.containsMouse ? 1 : 0.6
            font.family: picker.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.underline: resetMouse.containsMouse
            MouseArea {
              id: resetMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: picker.picked("")
            }
          }
        }
      }

      // Brightness
      Item {
        width: body.width
        height: Style.space(16)

        Rectangle {
          anchors.fill: parent
          anchors.topMargin: Style.space(3)
          anchors.bottomMargin: Style.space(3)
          radius: height / 2
          border.width: 1
          border.color: Util.alpha(picker.fg, 0.2)
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#000000" }
            GradientStop { position: 1; color: Logic.hsvToHex(picker.hue, picker.sat, 1) }
          }
        }
        Rectangle {
          width: Style.space(12)
          height: width
          radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          x: picker.val * (parent.width - width)
          color: picker.current
          border.width: 2
          border.color: picker.fg
        }
        MouseArea {
          anchors.fill: parent
          preventStealing: true
          cursorShape: Qt.PointingHandCursor
          function pick(mouse) {
            picker.val = Math.max(0, Math.min(1, mouse.x / width))
            picker.choose()
          }
          onPressed: function(mouse) { pick(mouse) }
          onPositionChanged: function(mouse) { if (pressed) pick(mouse) }
        }
      }

      // Five suggestions that complement the theme accent (no labels).
      Row {
        spacing: Style.space(10)

        Repeater {
          model: picker.suggestions

          Rectangle {
            required property string modelData
            readonly property bool chosen: picker.value === modelData
            width: Style.space(22)
            height: width
            radius: width / 2
            color: modelData
            border.width: chosen ? 2 : 1
            border.color: chosen ? picker.fg : Util.alpha(picker.fg, 0.25)
            scale: dotMouse.containsMouse ? 1.12 : 1
            Behavior on scale { NumberAnimation { duration: 90 } }

            MouseArea {
              id: dotMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                picker.syncFrom(parent.modelData)
                picker.picked(parent.modelData)
              }
            }
          }
        }
      }
    }
  }
}
