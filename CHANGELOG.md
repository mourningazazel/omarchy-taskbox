# Changelog

## 1.2.0 — 2026-09-26

- Hover previews: resting the pointer on a minimized window's button shows
  a small thumbnail of the window under it (beside it on a vertical bar),
  200 px wide and at most 120 px tall, without the title the button already
  shows. Setting *Hover previews*:
  `minimized` (default), `all` or `off`.
- Previews are taken by `grim` in a separate process (part of Omarchy's base
  install), so they work the same on any GPU, driver or Qt renderer, and a
  failed capture only shows the app icon instead. A window is captured at
  most once every 3 seconds; pictures stay in `$XDG_RUNTIME_DIR` (private,
  in memory) and are deleted when the window closes.
- Tooltips only when they add something: a button shows its window's title
  in a tooltip only if the title is cut off or hidden (narrow buttons, titles
  off, vertical bar) and no preview is shown. Otherwise the window's hover
  highlight is the cue. (They also show again on Omarchy builds whose bar
  requires widgets to report `tooltipHovered`.)
- The preview card shows the title too when the button can't show all of it.

## 1.1.1 — 2026-09-26

- The settings popup has a close button, closes with Esc (the first Esc
  closes the colour picker if it's open), and closes when you click
  anywhere outside it. It's now an Omarchy keyboard panel, so Esc and
  typing into its fields work reliably.

## 1.1.0 — 2026-09-26

- Custom highlight colour for the buttons (settings → *Custom highlight
  color*): a hex field plus a colour picker — hue/saturation wheel,
  brightness, and five suggestions that complement the theme accent at the
  lightness of the default highlight. Empty = the theme's default.
- Icon-only buttons are compact when titles are off (thanks @seth-reee).

## 1.0.0 — 2026-09-25

First public release of Taskbox.

- Window buttons for the current workspace: icon, title, close button; theme
  and font aware; dynamic width with `+N` overflow; oldest-left ordering.
- Hover highlights the window; click focuses without warping the cursor.
- Alt+× force kill; Alt+drag moves the taskbar within the bar.
- Drag a button onto a workspace number to send the window there without
  following; it fits in (tile/float, never fullscreen) and is focused when
  you next open that workspace.
- Minimize / restore, with minimized windows kept (dimmed) on the taskbar.
- Right-click window menu and a built-in settings popup.
- Icon-only column on left/right bars.
- Self-contained Hyprland integration loaded at runtime (no config edits);
  removing Taskbox reloads Hyprland once to clear it.
- Minimized windows remember their workspace across restarts (window tag).
- Stale hover highlights are cleared on start; a startup self-check reports
  any feature an Omarchy update made unavailable.
- Web-app windows (Omarchy/Chromium app mode) get their web app's icon.
- Buttons are kept across window changes (no flicker, hover/drag/tooltip
  state survives); menus, drags, tooltips and hover never outlive their
  window; reused window addresses can't inherit old state.
- Diagnostics over IPC: `omarchy-shell mourningazazel.taskbox state|check|icon|…`.
- Tests: unit (Logic.js), Lua (against a strict mock Hyprland), qmllint,
  consistency checks, and a live integration suite; CI on GitHub Actions.
- Developer docs for humans and AI agents (`AGENTS.md`) and `tools/dev.sh`.
- Ready for Omarchy 4.0.4's plugin API: Taskbox only uses the restricted bar
  facade third-party widgets get, and reads the bar layout from its own
  place in the scene; Alt+drag uses the bar's own widget drag.
- Works with third-party workspaces widgets (incl. per-monitor and named
  workspaces), other plugins' minimize conventions, replacement bars, and
  trays/drawers hosting widgets.
- Alt+× decides force-kill from the real key state (`hl.is_key_down`).
- Multi-monitor: tested on a virtual second monitor (per-monitor windows,
  sizing, fractional scales, focus without cursor warps, restore to the right
  monitor, hotplug); no IPC warnings with several instances.
