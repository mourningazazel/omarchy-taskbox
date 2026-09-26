import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Logic.js" as Logic   // copied next to it by run.sh (Quickshell only
                             // loads files from inside the config folder)

// Harness for tests/renderers/run.sh: runs the hover preview's display path —
// the real capture script (grim → PNG) and a Qt Image showing it — in a
// separate Quickshell process, so the Qt renderer can be switched per run
// (OpenGL, GLES, Vulkan, software, llvmpipe). Sits on the background layer and
// takes no input. Prints one line: RESULT {capture, image, api}.
ShellRoot {
  id: shell
  readonly property string out: Quickshell.env("TB_OUT")
  property var result: ({})
  function done(k, v) { var r = result; r[k] = v; result = r }

  PanelWindow {
    WlrLayershell.layer: WlrLayer.Background
    anchors { bottom: true; left: true }
    implicitWidth: 200
    implicitHeight: 120
    color: "black"
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    Process {
      id: proc
      property double t0: 0
      onExited: function(code) {
        shell.done("capture", { exit: code, ms: Date.now() - t0 })
        img.source = "file://" + shell.out + "/capture.png"
      }
    }
    Component.onCompleted: {
      proc.command = Logic.previewCaptureArgs(Quickshell.env("TB_ADDR"), shell.out + "/capture.png", 400, 240)
      proc.t0 = Date.now()
      proc.running = true
    }

    Image {
      id: img
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: false
      mipmap: true
      onStatusChanged: if (status === Image.Ready) grab.start()
    }
    Timer {
      id: grab
      interval: 150
      onTriggered: img.grabToImage(function(r) {
        r.saveToFile(shell.out + "/shown.png")
        shell.done("image", img.implicitWidth + "x" + img.implicitHeight)
      })
    }
    Timer {
      interval: 4000
      running: true
      onTriggered: {
        var apis = ["Unknown", "Software", "OpenVG", "OpenGL", "Direct3D11", "Vulkan", "Metal", "Null", "Direct3D12"]
        shell.done("api", apis[img.GraphicsInfo.api] || String(img.GraphicsInfo.api))
        console.log("RESULT " + JSON.stringify(shell.result))
        Qt.quit()
      }
    }
  }
}
