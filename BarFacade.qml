import QtQuick

// Stand-in for Omarchy 4.0.4+'s PluginBarApi (shell/Ui/PluginBarApi.qml):
// from 4.0.4 on, third-party bar widgets receive that restricted facade as
// `bar` instead of the host Bar. This mirrors its public surface exactly —
// nothing more — over the real bar, so the whole plugin can be exercised
// against the restricted API on older Omarchy too.
//
// Enabled by the (undocumented, test-only) widget setting `emulateFacade`:
//   tests/live/run.sh --facade
// tests/api/facade.sh checks that Taskbox only uses these members of `bar`.
// Keep in sync with PluginBarApi.qml when Omarchy changes it.
QtObject {
  id: facade

  property var real: null
  // Third-party plugins get a scoped shell facade here; Taskbox doesn't use it.
  readonly property var shell: null

  readonly property color foreground: real ? real.foreground : "transparent"
  readonly property color barForeground: real ? real.barForeground : "transparent"
  readonly property color background: real ? real.background : "transparent"
  readonly property color urgent: real ? real.urgent : "transparent"
  readonly property string fontFamily: real ? real.fontFamily : ""
  readonly property string position: real ? real.position : "top"
  readonly property bool vertical: real ? real.vertical : false
  readonly property int barSize: real ? real.barSize : 0
  readonly property bool transparent: real ? real.transparent : false
  readonly property bool foregroundAnimationEnabled: real ? real.foregroundAnimationEnabled : true
  readonly property bool centerSectionRevealHeld: real ? real.centerSectionRevealHeld : false
  readonly property bool centerHoverRevealSuppressed: false
  readonly property var activePopout: real ? real.activePopout : null
  readonly property var clickTargets: []
  // The real facade hands out a detached copy of the layout config.
  readonly property var layoutConfig: real && real.layoutConfig ? JSON.parse(JSON.stringify(real.layoutConfig)) : ({})
  readonly property var foreignPopoutMarker: ({ foreign: true })

  function setCenterHoverRevealSuppressed(value) {}
  function showTooltip(target, text) { if (real) real.showTooltip(target, String(text || "")) }
  function hideTooltip(target) { if (real) real.hideTooltip(target) }
  function registerClickTarget(target) { if (real && real.registerClickTarget) real.registerClickTarget(target) }
  function unregisterClickTarget(target) { if (real && real.unregisterClickTarget) real.unregisterClickTarget(target) }
  function requestPopout(owner) { if (real) real.requestPopout(owner) }
  function releasePopout(owner) { if (real) real.releasePopout(owner) }
  function switchPanelFrom(owner, direction) { return real && real.switchPanelFrom ? real.switchPanelFrom(owner, direction) : false }
  function targetBelongsToWindow(target, window) { return real && real.targetBelongsToWindow ? real.targetBelongsToWindow(target, window) : false }
  function moduleWidgets(id) { return real ? real.moduleWidgets(String(id || "")) : [] }
  function run(command) { if (real) real.run(String(command || "")) }
}
