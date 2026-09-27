import QtQuick
import Quickshell
import Quickshell.Wayland
import "taskbox" as TB

// Harness for tests/qml/load.sh: the widget in its own Quickshell, hosted by
// a stand-in bar whose run() does nothing — so Taskbox never loads its Lua or
// touches a window, and the real shell isn't involved. Sits on the background
// layer and takes no input.
ShellRoot {
  QtObject {
    id: fakeBar
    readonly property color foreground: "#cacccc"
    readonly property color barForeground: "#cacccc"
    readonly property color background: "#1e1e2e"
    readonly property color urgent: "#e06c75"
    readonly property string fontFamily: ""
    readonly property string position: Quickshell.env("TB_POSITION") || "top"
    readonly property bool vertical: position === "left" || position === "right"
    readonly property int barSize: 30
    readonly property var layoutConfig: ({})
    // The rest of Omarchy's plugin facade (PluginBarApi / BarFacade.qml),
    // read by Taskbox's facade stand-in and Omarchy's popups.
    readonly property var shell: null
    readonly property bool transparent: false
    readonly property bool foregroundAnimationEnabled: true
    readonly property bool centerSectionRevealHeld: false
    readonly property bool centerHoverRevealSuppressed: false
    property var activePopout: null
    readonly property var clickTargets: []
    readonly property var foreignPopoutMarker: ({ foreign: true })
    function setCenterHoverRevealSuppressed(value) {}
    function switchPanelFrom(owner, direction) { return false }
    function targetBelongsToWindow(target, window) { return false }
    property var ran: []
    function run(command) { ran.push(String(command)) }
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function moduleWidgets(id) { return [widget] }
  }

  PanelWindow {
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "taskbox-load-test"
    anchors { top: true; left: true; right: true }
    implicitHeight: 30
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    TB.Taskbox {
      id: widget
      moduleName: "mourningazazel.taskbox"
      bar: fakeBar
      settings: ({ preview: "all", showTitle: true })
    }
  }
}
