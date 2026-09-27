# AGENTS.md — working on Taskbox

Guide for AI coding agents (and humans) diagnosing or extending this plugin.
Read the **Hard rules** before running anything against a live Hyprland
session: this is a desktop component, and mistakes land on the user's real
windows. Run `tools/dev.sh test` before and after every change.

## What it is

Taskbox (`mourningazazel.taskbox`) is an Omarchy shell **bar-widget** plugin:
a Windows-style taskbar with one button per window on the monitor's active
workspace (plus that workspace's minimized windows). The shell is a single
Quickshell process (`omarchy-shell`); this plugin is QML loaded into it, plus a
Lua module it loads into Hyprland at runtime.

Target: Omarchy 4.0+ (Hyprland 0.56 with the Lua config — **Lua 5.5** —
Quickshell 0.3). From Omarchy **4.0.4**, third-party widgets receive a
restricted bar facade (`PluginBarApi`) instead of the host Bar; Taskbox is
written against that facade only (see [Host API](#host-api-omarchy-404-plugin-facade)).
Without the Lua config (`Hyprland.usingLua == false`) the widget degrades to
list/focus/close only (`integrated` stays false).

## File map

| File | Role |
|---|---|
| `manifest.json` | Plugin manifest. `barWidget.defaults` = setting defaults; `schema` is metadata only (Omarchy 4.0 has no UI that reads it yet). |
| `Taskbox.qml` | Entry point / root widget (`BarWidget`): window model, sizing, drag, actions, icons, popups, IPC diagnostics. |
| `BarFacade.qml` | Exact stand-in for Omarchy 4.0.4's `PluginBarApi`, used when the test-only setting `emulateFacade` is on. |
| `HyprBridge.qml` | All Hyprland I/O: loads the Lua, `call()`s it, turns its events into properties (integrated, altHeld, hover, origins). |
| `lib/Logic.js` | Pure logic (`.pragma library`): settings, quoting, events, ordering, minimized filtering, layout, click/menu rules, icon candidates, shell commands. **Unit-tested.** |
| `TaskButton.qml` | One button (horizontal: icon + title + ×; vertical: icon only). Mouse: click, middle, right, drag, Alt+drag. |
| `TaskMenu.qml` | Right-click window menu (`PopupCard`). |
| `ColorPicker.qml` | Colour popover for the custom highlight (wheel, brightness, 5 suggestions), shown as a card inside the settings popup. |
| `SettingsPopup.qml` | Settings popup (`KeyboardPanel`) from `qs.Ui` controls; writes via `saveSetting()`. |
| `WindowPreview.qml` | Hover thumbnail (`PopupWindow` anchored like the bar's tooltip): hover/show timers, the grim capture `Process`, per-window picture cache, icon fallback. |
| `hypr/taskbox.lua` | Hyprland side: Alt binds, hover rule, hooks, and the `Taskbox.*` actions. **Tested against a mock `hl`.** |
| `tests/` | See [Testing](#testing). |
| `tools/dev.sh` | Dev helpers: test, ipc, reload, logs, validate, state, lua, events, probe windows. |
| `tests/renderers/` | Renderer matrix for previews: the capture + display path in a separate `qs -p` per Qt renderer. |
| `.github/workflows/test.yml` | CI: consistency + unit + Lua tests. |
| `docs/` | README screenshots. |

## Architecture

```
omarchy-shell (Quickshell)
└─ bar (omarchy.bar, one window per monitor)
   └─ ModuleSlot (per layout entry; region = left|center|right)
      └─ Taskbox.qml ── uses lib/Logic.js (pure)
         └─ HyprBridge.qml ──hyprctl dispatch──►  Hyprland Lua: _G.Taskbox (hypr/taskbox.lua)
                ▲                                      │
                └──────── Hyprland.rawEvent ◄──────────┘  custom>>taskbox>>…, custom>>taskbox-alt>>1|0,
                                                          configreloaded>>
```

Keep the split: anything that can be a pure function goes in `Logic.js` with
a test; Hyprland traffic goes through `HyprBridge`; `Taskbox.qml` wires them
to the view.

### Host API (Omarchy 4.0.4 plugin facade)

Third-party widgets get `bar` = `PluginBarApi` (Omarchy `shell/Ui/PluginBarApi.qml`):
theme values, `position`/`vertical`/`barSize`, `run`, `showTooltip`/`hideTooltip`,
`requestPopout`/`releasePopout`, `registerClickTarget`, `moduleWidgets`,
`layoutConfig`. No `moduleSlots`, no drag API, no `shell.mutateShellConfig`.

- All bar access goes through **`host`** (`bar`, or `BarFacade` when
  `emulateFacade` is on). `tests/api/facade.sh` fails if any QML uses a member
  the facade lacks, and (on 4.0.4+) if `BarFacade.qml` drifts from the real one.
- Theme values go through `hostValue(name, fallback)`: replacement bars
  (e.g. Shibumi) don't all provide `barForeground`/`urgent`/`fontFamily`.
- The bar **layout** is read from the scene, which Omarchy documents as
  reachable ("a visual widget … can walk its parent hierarchy"): `mySlot()`
  walks our parents to the slot hosting us (`activeItem === root`, has
  `region`); `barSlots()` walks our bar window for items with
  `region`/`activeItem`/`moduleName`. Used for sizing, the reorder guard and
  drop targets. Hosted outside a slot (tray, drawer) → natural size.
- **Alt+drag** moves the widget with the bar's *own* drag: while Alt is held
  the reorder guard is lifted, so the press reaches the bar's reorder
  MouseArea. (It isn't hover-enabled, so our buttons keep hover; clicks still
  fall through to our MouseAreas because Taskbox registers no click target.)

### Window model

`_records` maps every `Hyprland.toplevels` entry to a plain record
(`{key, workspaceId, workspaceName, activated, toplevel}`) and prunes state
for closed windows. `windows` = this workspace's records + `Logic.minimizedFor`
(parked windows whose origin is here, or unknown), ordered by
`Logic.ordered` (first-seen, oldest left). `Logic.layout` sizes them and
`Logic.pickShown` splits shown / overflow (focused window always shown).

The buttons come from **`ScriptModel`s** (`shownModel`, `hiddenModel`). They
diff the list by object identity, so a button survives other windows
opening/closing — a plain JS-array model rebuilds *every* delegate on any
change, which kills hover state, drags and tooltips.

Keys are addresses without `0x`, lowercased (`Logic.addressKey`). **Hyprland
reuses addresses**: that's why state is pruned (QML: `Logic.prune`; Lua: the
`window.close` hook clears `T.last` and pending arrivals).

### Hyprland integration

- `hyprctl dispatch '<expr>'` evaluates a **Lua expression** in Hyprland
  (wrapped as `return hl.dispatch(<expr>)`), so every function in
  `hypr/taskbox.lua` returns a dispatcher — `reply()` = a harmless
  `hl.dsp.event("taskbox>>…")` that also serves as the result channel.
- `HyprBridge.attach()` runs `dofile("<plugin>/hypr/taskbox.lua")` then
  `Taskbox.attach()`, when it gets its `bar`, on every `configreloaded`
  (**a Hyprland reload wipes all runtime Lua state**: globals, binds, rules,
  hooks), and every 5 s until it answers (≤12 tries; covers login races).
- `Taskbox.attach()` installs once per Lua state (`T.installed`): 4 Alt binds
  (press/release on `Alt_L`/`Alt_R`, `non_consuming`, `ignore_mods`), the
  `taskbox-hover` window rule, and hooks for `workspace.active`,
  `window.move_to_workspace`, `window.open`, `window.close`. It replies
  `taskbox>>attached,<version>` → `integrated = true`.
- On its first `attached`, each instance calls `Taskbox.hello()`: clears any
  `taskbox-hover` tag a crashed shell left behind and replies
  `taskbox>>origins,<address>=<id>;…`.
- Calls go through `HyprBridge.call(fn, args)` → `Logic.luaCall` (every arg
  a Lua string literal; function names must match `^[a-z_]+$`). Actions:
  `focus`, `send` (id or `name:<workspace>`), `minimize`, `restore`,
  `toggle_floating`, `toggle_maximized`, `close`, `close_or_kill`, `kill`.
- The **×** calls `close_or_kill`, which checks `hl.is_key_down("Alt_L"/"Alt_R")`
  in Hyprland at click time. The QML `altHeld` (from the Alt bind events) is
  only for the red × and for lifting the reorder guard; a missed release must
  never turn a close into a SIGKILL.
- **Cleanup:** on destruction the widget runs `Logic.cleanupCommand`: a
  detached, flock'd script that waits 2 s, asks the shell
  `listPlugins`, and runs `hyprctl reload` only if the shell answers and
  says Taskbox is disabled or gone. (Instances also die on restarts, monitor
  changes, moves and when a tray/drawer host closes; "enabled" is Omarchy's
  own notion — the id anywhere in shell.json — so those don't reload.)
- **IPC:** only the first instance (`ipcPrimary`) registers the target;
  it answers for all monitors via `moduleWidgets()`. `bar` is injected
  *after* a widget is created, so with no host yet an instance is not primary
  (otherwise every monitor's instance registers for a moment and Quickshell
  warns "another handler is registered"). `settings`/`overflow` act on the
  focused monitor's instance, like Omarchy's own summon.

### Origins (minimized windows)

Minimized = parked on the configured workspace or a known convention
(`Logic.KNOWN_MINIMIZE_WORKSPACES`: `minimized` — hyprbars, omadock;
`omarchy-minimized` — window-shelf, qol-desktop-plus).

`hypr/taskbox.lua` tracks each window's last regular workspace (`T.last`).
When a window moves to any special workspace it's tagged `taskbox-from-<id>`;
moving to a regular workspace removes the tag; moving between special
workspaces keeps it. Tags live on the window in Hyprland, so they survive
shell restarts **and** Hyprland reloads, and moves from anywhere (hyprbars,
keybinds) are caught. The widget also learns origins live and merges the
`hello()` report (`_stateRev` makes the bindings re-read).

### Why the odd mechanisms exist

| Mechanism | Reason |
|---|---|
| Alt tracked via Hyprland binds → `custom>>taskbox-alt>>1/0` | The bar layer surface has `WlrKeyboardFocus.None`; Qt never sees modifiers (`mouse.modifiers` is always 0). |
| `altExpiry` (10 s) + clearing Alt after force kill | Hyprland sometimes drops the release bind (e.g. the window under it died), which left the × stuck red. |
| Hover = tag `taskbox-hover` + window rule | Highlights a window without focusing it. Both border colours are set because the hovered window is usually *unfocused*. |
| `with_config(... no_warps ...)` around focus/move | Stops the cursor jumping to the window on click/drop, while restoring the user's setting. |
| `on_focus_under_fullscreen = 2` during arrival focus | Omarchy's default (1) hands a maximize to the newly focused window; 2 restores it instead. |
| `send()` survey of the target workspace | Dropped windows never arrive fullscreen; they tile if the target has tiled windows, float if it only has floating ones. |
| Reorder guard (`setReorderBlocked`) | The bar puts a press-grabbing `MouseArea` over every slot for widget reordering; it only forwards clicks, so it swallowed button drags. Disabled for our slot while a button is hovered/dragged (and Alt isn't held), then its binding restored. |
| Drop targets via `Logic.dropTargetOf` | Any workspaces widget (id contains "workspace"); a button's real `workspace.id` wins over its displayed number (per-monitor setups), then `workspaceId`, numeric `modelData`, `modelData.id`, finally `name:<name>`. |
| `popupOwner` proxy | The bar draws an "open panel" marker under the widget that owns the active popout; across a wide taskbar it lands between buttons. |
| `_state`, `_icons` mutated in place + `_stateRev` / `_iconRev` | Bindings may record into these without reassigning a property (which would re-trigger the binding: a *binding loop*). Revisions are bumped only from outside bindings, to invalidate. |
| `recompute()` uses slot `region` + a 750 ms timer | Neighbours (clock, weather) resize silently; live positions lag during relayout, and our own size must not feed back into the budget. |
| Web-app icons by URL host | Omarchy web apps have no `StartupWMClass`; Chromium classes them `chrome-<host>__<path>-<profile>`, matched to the desktop entry whose Exec URL has that host. |
| Settings is a `KeyboardPanel`, not a `PopupCard` | xdg popups (PopupCard) only get keyboard focus after a click routes it through the bar, so Esc and typing failed when opened any other way (and on re-opens). Omarchy's `KeyboardPanel` primes layer-shell keyboard focus on open (`focusTarget: escapeCatcher`) and dismisses on outside clicks. Menus/overflow need no keys and stay `PopupCard`s. |
| Colour picker is a card inside the settings popup | A second `PopupCard` from inside the settings popup starts its own Hyprland focus grab, which cancels the settings popup's grab and closes it. |
| `previewHighlight` | A picked/typed colour shows on the buttons immediately; the `omarchy bar set` write is debounced, and the preview is dropped once the setting matches. |
| `checkCompat()` 6 s after start | Lists features whose Omarchy prerequisites are missing (`unavailable`), logs `[taskbox] unavailable here: …` once, and shows it in the settings popup. |
| Button `Component.onDestruction` | A window can close under the pointer or mid-drag: hide tooltips, drop hover, cancel the drag. |
| Previews via `grim -T <stableId>`, not `ScreencopyView` | Quickshell's in-process `ScreencopyView` imports the captured dmabuf with EGL/Vulkan and calls `qFatal()` if the driver refuses (`eglCreateImage` failure etc.) — that would abort the whole shell (bar, notifications) on an unlucky GPU/driver combo. grim runs as its own process with shm buffers: the compositor does the copy (as for screenshots), the shell only decodes a small PNG. A failure costs one thumbnail (exit 3/4 → icon placeholder). ~100 ms per capture incl. hyprctl + jq; ~35 ms CPU in grim. |
| Preview timing: capture at 150 ms, show at 400 ms, hide after 150 ms | Sweeping across the taskbar starts nothing; the picture is usually ready when the card appears (same delay as the bar's tooltips); moving between buttons switches without flicker. One capture per window per `PREVIEW_REFRESH_MS` (3 s), also while the card stays up (a hidden app redraws after being captured, so the refresh catches up). |
| Preview files: `$XDG_RUNTIME_DIR/taskbox-preview/<address>.png`, 0600 | Written to a temp name and renamed (no half-read PNGs); deleted when the window closes (`forgetClosed`) and the folder when Taskbox is disabled (cleanup script). `?rev` on the Image URL forces a reload (`cache: false`). |
| `tooltipHovered` on buttons | Omarchy's bar (4.0.3rc4+) only shows/keeps a tooltip while the target reports `tooltipHovered === true`. |
| `wantsTooltip` / `titleFullyVisible` | User preference: a button's tooltip only when it adds information — the title is hidden or elided (`Text.truncated`) and no preview card is shown; otherwise the window's hover highlight is the confirmation. Reactive, not `onEntered`: an on-hover × narrows the title *after* the pointer arrives. The preview card's title follows the same rule. `ipc state` reports `titleVisible` per window. |
| Preview suppressed after a click until the pointer leaves | As on Windows; also stops a just-restored window's card reappearing (and `visibleNow` re-checks eligibility). |

## Omarchy internals relied on (re-check after Omarchy updates)

Not public API — if something breaks after `omarchy update`, check these first
(sources under `$OMARCHY_PATH/shell/`, usually `/usr/share/omarchy/shell/`).
`tools/dev.sh ipc check` and `ipc state` (`slotFound`, `barSlots`,
`reorderAreaEnabled`) report what Taskbox can see.

- `plugins/bar/Bar.qml` **ModuleSlot** shape: `region`, `activeItem`,
  `moduleName`; the widget sits in a `Loader` inside it. Its reorder
  `MouseArea` (child of the slot, found by `canReorder` + `dragThreshold`) is
  not hover-enabled and forwards clicks via `pressModuleClickTarget` →
  `moduleTargetClickable` (needs `triggerPress`, which Taskbox doesn't have,
  so clicks fall through).
- Summon contract (`shell.qml` → `summonBarWidget`): a bar-widget-only plugin
  gets `open()`, `close()` and `opened` called/read by
  `omarchy-shell shell toggle <id>`.
- `omarchy-shell shell listPlugins` JSON with `id` / `enabled` (cleanup).
- Workspaces widgets: drop targets are found by walking `childAt()` to a
  delegate with `workspace` / `workspaceId` / `modelData`.
- `Ui/PopupCard.qml`: default property `contentItem` (Items only); `owner` for
  popout coordination and `close()`; uses only facade members of `bar`.
- `Ui/BarWidget.qml`: `bar`, `settings`, `setting()`, `vertical`, `barSize`.
- `plugins/bar/Bar.qml` tooltips: `showTooltip(target, text)` needs
  `target.tooltipHovered === true`, re-checked every 100 ms.
- `Color.tooltip.{background,text,border}` for the preview card.
- Outside Omarchy's shell: `grim` ≥ 1.5 (`-T`, in `omarchy-base.packages`)
  and Hyprland's `stableId` in `hyprctl clients -j` (the ext-foreign-toplevel
  identifier grim expects).

## Upstream watch list (checked 2026-09-25)

| Upstream | State | Why it matters |
|---|---|---|
| Omarchy 4.0.4 (released) / `quattro` | Third-party widgets get `PluginBarApi` instead of the host Bar | Handled: facade-only `host`; covered by `tests/api/facade.sh` and `run.sh --facade` |
| Omarchy `quattro` | ModuleSlot/reorder MouseArea/click forwarding unchanged vs 4.0.3 | Re-diff `Bar.qml` ModuleSlot on updates |
| Hyprland `main` #15539 | Legacy `.conf` config removed | Lua config becomes mandatory (good) |
| Hyprland `main` #15831 | Missing windows/workspaces are pushed as `nil` | Handled; Lua tests feed nil to every hook |
| Hyprland `main` #15540 | `window.open` fires later (`openLate`) | Fine: workspace is set by then |
| Hyprland `main` #15767 | `hyprctl --batch` splits on every `;` | Taskbox never uses `--batch` |
| Hyprland `main` #15669 | Deprecation notices for user-set options | Only `special_scale_factor` so far; Taskbox sets none of the listed |
| Quickshell master | `ScriptModel` compares native objects by identity only | Matches how Taskbox uses it |

## Hard rules

0. **Only use facade members of `bar`** (via `host`); `tests/api/facade.sh`
   enforces it. Reach the layout through the scene, never the Bar object.

1. **Never remove Hyprland binds at runtime** (`bind:remove()`), and don't
   disable/remove the rule or hooks either. Removing one bind handle removes
   every bind on that key; removing the sibling afterwards **aborts Hyprland
   0.56** (this crashed a user session into safe mode during development).
   Install once per Lua state; to get rid of everything, `hyprctl reload`.
   The Lua tests enforce this (the mock errors on any removal).
2. **Dispatchers fall back to the focused window.** An unknown option key or a
   `window = "address:…"` that doesn't resolve silently targets the *active*
   window. Every `Taskbox.*` action checks `hl.get_window()` first (tested).
   Constructing a dispatcher does **not** validate its arguments.
3. **Test window actions only on probe windows** (`tools/dev.sh probe spawn`)
   on a hidden special workspace. Launch them with the placement on the launch
   itself — `hl.dsp.exec_cmd(cmd, { workspace = "special:x silent" })` — not
   with a class-matching window rule: some apps (Chromium) set their class
   after mapping, so the rule misses and the window lands on the user's screen.
4. **Never `pkill -f <pattern>` from a shell whose own command line contains
   the pattern** (e.g. inside `bash -c "…; pkill -f foo"`): it kills itself.
   Kill by PID, or run it from a script file.
5. **Bindings must not assign properties** they (transitively) read — that's
   a binding loop (the log says `Binding loop detected for property`). Cache
   in a plain object mutated in place; invalidate from signal handlers.
6. `hl.get_config()` returns gradient colours as hex **strings**
   (`"0xC0D97B3F"`) inside `{ colors = {…} }`; `tonumber()` them before maths.
   (Bitwise operators exist in Lua 5.5 but fail on strings/floats.)
7. Don't name QML methods like JS globals (`escape`, `eval`, `parseInt`, …):
   the engine refuses them at load ("Illegal method name") and qmllint
   doesn't notice; `tests/qml/lint.sh` checks for it.
8. `PopupCard` children must be Items: put `Timer`s etc. inside a child Item.
9. After editing QML, run `tools/dev.sh reload`: the shell caches components
   by file URL, so hot reload doesn't always pick changes up. Check
   `pgrep -xc quickshell` is 1 afterwards (concurrent restarts can spawn two).
10. Quickshell's `DesktopEntries.applications` omits `NoDisplay=true` entries.
11. `omarchy bar set <id> <key> <value>` stores strings unless `--json` is
    passed; `Logic.normalizeSettings` accepts both.

## Testing

```bash
tools/dev.sh test               # offline: consistency + unit + Lua + qmllint (~2 s)
tools/dev.sh test live          # live, safe: ~40 checks via IPC and probe windows (~30 s)
tools/dev.sh test live --full   # also Hyprland reload, shell restart, disable/enable,
                                # 20-window stress, left-bar layout (~1–2 min, bar blinks)
tools/dev.sh test live --facade # everything behind an exact 4.0.4 plugin facade (combines with --full)
tools/dev.sh test multimonitor  # on a virtual second monitor (add --facade too)
tools/dev.sh test renderers     # hover previews under OpenGL, GLES, Vulkan, software, llvmpipe
```

| Suite | Covers | Needs |
|---|---|---|
| `tests/manifest.sh` | manifest rules (mirrors `omarchy plugin validate`); defaults agree across manifest / schema / `Logic.DEFAULTS` / README; version agrees across manifest / Lua / CHANGELOG | jq, node |
| `tests/unit/logic.test.mjs` | every `Logic.js` function, incl. quoting round-trips through real bash and Lua, layout invariants over 240 size combinations | node ≥ 20, lua |
| `tests/lua/taskbox_spec.lua` | `hypr/taskbox.lua` against `mock_hl.lua`: install-once, never-remove, missing-window guard, config restore, send fit-in, arrival focus, origins, pruning, toggles | lua 5.4/5.5 |
| `tests/api/facade.sh` | QML only uses members of Omarchy 4.0.4's plugin facade; `BarFacade.qml` matches the installed `PluginBarApi.qml` (4.0.4+) | — |
| `tests/qml/lint.sh` | qmllint for syntax, imports, unresolved types, duplicate bindings, required props (style categories off) | Omarchy install, qt6 qmllint |
| `tests/live/multimonitor.sh` | the plugin on a **virtual second monitor** (`hyprctl output create headless`): one instance per monitor, per-monitor windows/sizing/overflow, focus across monitors without warping, per-monitor hover/menus/settings/previews, restore to the clicked monitor, workspace switches on the other monitor, windows moving between monitors, scales 1 / 1.25 / 1.5 / 2 (incl. preview pixel density), unplug/replug (with a preview open) | Omarchy desktop |
| `tests/live/run.sh` | the running plugin end to end, incl. hover previews (delay, 3 s reuse/refresh, switching, menu hides it, icon fallback via `previewFailure`, modes, window closing deletes its picture); fails on any QML error / binding loop logged during the run | Omarchy desktop |
| `tests/renderers/run.sh` | the preview's capture + display path in a separate Quickshell per Qt renderer (default, OpenGL ES, Vulkan, software, llvmpipe); every renderer must show the same picture | Omarchy desktop, qs |

The Lua and qmllint suites were mutation-tested (deliberately broken code must
fail them). When you add behaviour, add a test in the matching suite; when you
fix a bug, add the test that would have caught it.

**Multi-monitor testing without a second screen:** `hyprctl output create
headless <NAME>` adds a monitor Hyprland, Quickshell and Omarchy treat as real
(own bar, own Taskbox instance, own workspace) that nobody sees; `hyprctl
output remove <NAME>` unplugs it. Launch test windows straight onto its
workspace (`exec_cmd(cmd, { workspace = "<id> silent" })`). Keep its position
`auto`: parking it far away made Hyprland re-lay-out the real screen (its
`position = "auto"` rule) and dragged the cursor and focus onto the virtual
monitor. Monitor rules added with `hyprctl eval 'hl.monitor(…)'` persist until
the next `hyprctl reload`.

`mock_hl.lua` is strict on purpose: it errors on bind/rule/hook removal, on
dispatches to unknown windows, on `follow = true` moves, and simulates window
state and hooks so tests assert outcomes, not just calls.

## Diagnostics API (IPC)

```bash
tools/dev.sh ipc state          # JSON per monitor: settings, layout numbers, windows (+icon, minimized, shown)
tools/dev.sh ipc check          # re-run the self-check → unavailable features
tools/dev.sh ipc icon <appId>   # how an icon resolves (web-app host, candidates, desktop entry)
tools/dev.sh ipc dropTargets    # per monitor: workspace targets drag-and-drop would hit
tools/dev.sh ipc click <addr>   # left-click a window's button (restore / minimize / focus)
tools/dev.sh ipc hover <addr>   # hover-highlight a window ("" clears)
tools/dev.sh ipc preview <addr> # rest the pointer on its button: hover preview ("" hides)
tools/dev.sh ipc previewFailure true|false  # tests: make captures fail (icon fallback)
tools/dev.sh ipc menu <addr>    # open a window's menu
tools/dev.sh ipc settings | colorPicker | overflow | closePopups
```
(`tools/dev.sh ipc …` = `omarchy-shell mourningazazel.taskbox …`.)

## Dev workflow

```bash
tools/dev.sh validate     # omarchy plugin validate
tools/dev.sh reload       # restart the shell after QML edits
tools/dev.sh logs         # recent Taskbox/QML errors (use -f to follow)
tools/dev.sh state        # expect: 1 shell, 4 alt binds, taskbox>>state,true,true,<ver>
tools/dev.sh events 20    # watch taskbox>> / taskbox-alt>> / configreloaded events

# Lua side: edit hypr/taskbox.lua, then load it into a fresh Lua state
hyprctl reload            # the widget re-attaches within ~1 s (new hooks need this)

# Try an action on a throwaway window
P=$(tools/dev.sh probe spawn | head -1)
tools/dev.sh lua "Taskbox.toggle_maximized(\"$P\")"
hyprctl clients -j | jq --arg a "$P" '.[] | select(.address == $a) | {workspace, floating, fullscreen}'
tools/dev.sh probe clean
```

Lua API reference: `/usr/share/hypr/stubs/hl.meta.lua` (field names only; not
every argument is documented — verify on a probe window).
Quickshell types: `/usr/lib/qt6/qml/Quickshell/**/*.qmltypes`.

## Diagnosing

| Symptom | Likely cause / check |
|---|---|
| Taskbox missing from the bar | `tools/dev.sh logs` for a QML error; `tools/dev.sh state` for the bar entry; `omarchy plugin list`. |
| Drag / minimize / hover / Alt do nothing, menu only has Close + settings | `integrated` is false: `tools/dev.sh ipc state` / `state`; a `dofile` error shows as no `taskbox>>attached` event (`tools/dev.sh events`). |
| Alt+× closes instead of killing | Alt binds missing (`state`: alt binds = 0) or Alt stuck; watch `tools/dev.sh events` while pressing Alt. |
| Wrong / generic icon | `tools/dev.sh ipc icon <appId>` (appId from `ipc state`) shows each lookup step. |
| Dragging a button moves the whole taskbar | Reorder guard didn't find the bar's MouseArea (Bar.qml changed); see `reorderArea()`, `ipc check`. |
| Drop on a workspace number does nothing | `tools/dev.sh ipc dropTargets` empty → no workspaces widget found (id must contain "workspace") or `Logic.dropTargetOf` can't read its delegates. |
| Sent to the wrong workspace (multi-monitor) | The widget's delegates expose only a displayed number; `dropTargetOf` prefers `delegate.workspace.id`. |
| Buttons too wide/narrow, overlapping the left section | `ipc state` → `available`, `fitCount`, `buttonExtent`; `recompute()` / `Logic.freeSpace`. |
| Hover/tooltip/drag stuck after a window closed | Check `TaskButton` `onDestruction` and that buttons come from a `ScriptModel`. |
| A stray line under the taskbar while a popup is open | A popup is using the widget as `owner` instead of `popupOwner`. |
| Minimized window on the wrong taskbar | Its tags: `hyprctl clients -j \| jq '.[] \| {class, workspace: .workspace.name, tags}'` should include `taskbox-from-<id>`. |
| `Binding loop detected` in the log | Hard rule 5. The live suite fails on this. |
| Disabling Taskbox didn't clear its binds | The cleanup check needs `jq` and `flock`; see `Logic.cleanupCommand`. |
| Hyprland crashed / safe mode | `coredumpctl list Hyprland`; Hard rule 1. |

## Conventions

- Match the surrounding code: 2-space QML/Lua/JS, comments explain *why*.
- `Logic.js` stays ES5-ish with top-level `function` declarations (QML's
  `.pragma library` and the Node loader both rely on that).
- Colours, fonts and spacing only from `Style`, `Color`, `bar.*` (theme-aware);
  sizes via `Style.space()`.
- New settings: `manifest.json` `defaults` + `schema`, `Logic.DEFAULTS` +
  `normalizeSettings`, a property in `Taskbox.qml`, a control in
  `SettingsPopup.qml`, the README table (`tests/manifest.sh` checks they agree).
- New Hyprland actions: `function T.<name>(address, …)` that checks the window
  exists and returns `reply(...)`, a test in `taskbox_spec.lua`, and a QML
  wrapper using `call()`.
- Events/tags/globals are namespaced `taskbox` (`taskbox>>`, `taskbox-alt>>`,
  `taskbox-hover`, `taskbox-from-<id>`, `_G.Taskbox`).

## Release checklist

1. Bump the version in `manifest.json`, `hypr/taskbox.lua` (`T.version`) and
   add a `CHANGELOG.md` entry (`tests/manifest.sh` checks all three agree).
2. `tools/dev.sh test`, `tools/dev.sh test live --full`,
   `tools/dev.sh test live --full --facade`,
   `tools/dev.sh test multimonitor` (+ `--facade`) and
   `tools/dev.sh test renderers` — all green.
3. Re-check the [upstream watch list](#upstream-watch-list-checked-2026-09-25)
   against the latest Omarchy / Hyprland / Quickshell.
4. By hand (needs a real pointer): click / middle / right-click menu, ×,
   Alt+×, hover highlight and preview, drag to a workspace (then visit it), Alt+drag,
   minimize/restore, settings changes persist.
5. Commit, tag `vX.Y.Z`, push. Users update with `omarchy plugin update`.
