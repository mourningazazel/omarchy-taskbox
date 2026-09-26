-- Taskbox (mourningazazel.taskbox) — Hyprland side of the bar widget.
--
-- Nothing to install: the widget loads this at runtime with
--   hyprctl dispatch 'dofile("<plugin>/hypr/taskbox.lua")'
-- and then calls Taskbox.attach(). A Hyprland config reload wipes all runtime
-- state (binds, rules, hooks, globals), so the widget loads it again on every
-- `configreloaded` event.
--
-- Binds, the rule and the hooks are installed once per Hyprland Lua state and
-- are NEVER removed at runtime: removing a bind handle removes every bind on
-- that key, and removing the sibling handle afterwards aborts Hyprland
-- (0.56). To get rid of them, Hyprland reloads its config (the widget asks
-- for that when Taskbox is taken off the bar).
--
-- Tested against a mock `hl` in tests/lua (run: tools/dev.sh test).
--
-- Every public function returns a harmless event dispatcher, so each can be
-- called as `hyprctl dispatch 'Taskbox.fn(...)'`.

local T = _G.Taskbox or {}
_G.Taskbox = T

T.version = "1.1.0"
T.arrivals = T.arrivals or {}     -- workspace id -> window address
T.last = T.last or {}             -- window address -> last regular workspace id
T.installed = T.installed         -- binds / rule / hook are in place

local function selector(address) return "address:" .. address end
local function reply(text) return hl.dsp.event("taskbox>>" .. text) end

-- Run fn with a config value temporarily overridden, restoring it after.
local function with_config(section, key, value, fn)
  local previous = hl.get_config(section .. "." .. key)
  hl.config({ [section] = { [key] = value } })
  local ok, err = pcall(fn)
  hl.config({ [section] = { [key] = previous } })
  if not ok then error(err) end
end

-- Dispatchers silently fall back to the *focused* window when a selector
-- doesn't resolve, so every action checks the window exists first.
local function window_for(address)
  return hl.get_window(selector(address))
end

local function set_fullscreen_off(address, fullscreen)
  if fullscreen == nil or fullscreen == 0 then return end
  local mode = fullscreen == 1 and "maximized" or "fullscreen"
  hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "unset", window = selector(address) }))
end

local function untag_hover(address)
  hl.dispatch(hl.dsp.window.tag({ tag = "-taskbox-hover", window = selector(address) }))
end

-- The theme's focused-window border, as "rgb(rrggbb)". hl.get_config returns
-- gradient colours as hex *strings* ("0xC0D97B3F"), so convert first; the
-- alpha byte is dropped (the highlight is always opaque).
local DEFAULT_COLOR = 0xFFD97B3F

function T.active_color(value)
  local c = value
  if c == nil then c = hl.get_config("general.col.active_border") end
  local first = type(c) == "table" and c.colors and c.colors[1] or c
  local argb = tonumber(first) or DEFAULT_COLOR
  return string.format("rgb(%06x)", math.floor(argb) % 0x1000000)
end

------------------------------------------------------------------ origins
-- A window parked on a special workspace (minimized, scratchpad) is tagged
-- `taskbox-from-<id>` with the regular workspace it left, so the widget can
-- show it on the right taskbar. The tag lives on the window in Hyprland, so it
-- survives shell restarts and Hyprland reloads, and the hook catches moves
-- from anywhere (a hyprbars minimize button, keybinds), not just Taskbox.

local ORIGIN_PREFIX = "taskbox-from-"

local function origin_tags(window)
  local found = {}
  for _, tag in ipairs(window.tags or {}) do
    tag = tostring(tag)
    if tag:sub(1, #ORIGIN_PREFIX) == ORIGIN_PREFIX then found[#found + 1] = tag end
  end
  return found
end

local function set_origin(window, id)
  local wanted = id and (ORIGIN_PREFIX .. tostring(id)) or nil
  for _, tag in ipairs(origin_tags(window)) do
    if tag ~= wanted then
      hl.dispatch(hl.dsp.window.tag({ tag = "-" .. tag, window = selector(window.address) }))
    end
  end
  if wanted then
    for _, tag in ipairs(origin_tags(window)) do
      if tag == wanted then return end
    end
    hl.dispatch(hl.dsp.window.tag({ tag = "+" .. wanted, window = selector(window.address) }))
  end
end

local function remember(window)
  if window and window.workspace and not window.workspace.special then
    T.last[window.address] = window.workspace.id
  end
end

-- Hyprland reuses window addresses, so forget closed windows everywhere.
local function on_window_closed(window)
  if not window then return end
  T.last[window.address] = nil
  for key, address in pairs(T.arrivals) do
    if address == window.address then T.arrivals[key] = nil end
  end
end

local function on_window_moved(window, workspace)
  if not window or not workspace then return end
  if workspace.special then
    local from = T.last[window.address]
    if from then set_origin(window, from) end
  else
    T.last[window.address] = workspace.id
    set_origin(window, nil)
  end
end

------------------------------------------------------------------ lifecycle

-- A send target is a workspace id ("13") or a named workspace ("name:dev").
local function is_target(workspace, target)
  if not workspace then return false end
  if target:sub(1, 5) == "name:" then return workspace.name == target:sub(6) end
  return tostring(workspace.id) == target
end

local function on_workspace_active(workspace)
  if not workspace or workspace.special then return end
  local key = tostring(workspace.id)
  local address = T.arrivals[key]
  if not address and workspace.name then
    key = "name:" .. workspace.name
    address = T.arrivals[key]
  end
  if not address then return end
  T.arrivals[key] = nil

  -- Deferred so it lands after Hyprland restores the workspace's last focus.
  -- on_focus_under_fullscreen = 2 un-maximizes anything maximized there
  -- instead of handing the maximize to the dropped window.
  hl.timer(function()
    local window = window_for(address)
    if window and is_target(window.workspace, key) then
      with_config("misc", "on_focus_under_fullscreen", 2, function()
        hl.dispatch(hl.dsp.focus({ window = selector(address) }))
      end)
    end
  end, { timeout = 30, type = "oneshot" })
end

local function install()
  -- Alt held/released -> custom>>taskbox-alt>>1/0. The bar never has keyboard
  -- focus, so it can't see modifiers; non-consuming, so apps still get Alt.
  for _, key in ipairs({ "Alt_L", "Alt_R" }) do
    hl.bind(key, hl.dsp.event("taskbox-alt>>1"), { non_consuming = true, ignore_mods = true })
    hl.bind(key, hl.dsp.event("taskbox-alt>>0"), { non_consuming = true, ignore_mods = true, release = true })
  end

  -- Hovering a button tags its window: paint it like the focused window
  -- (both border colours, since it's usually unfocused), thicker, opaque.
  local color = T.active_color()
  local border = hl.get_config("general.border_size") or 2
  hl.window_rule({
    match = { tag = "taskbox-hover" },
    border_color = color .. " " .. color,
    border_size = border + 2,
    opacity = "1 override 1 override",
  })

  hl.on("workspace.active", on_workspace_active)
  hl.on("window.move_to_workspace", on_window_moved)
  hl.on("window.open", remember)
  hl.on("window.close", on_window_closed)

  -- Seed last-known workspaces (the Lua state is fresh after every reload).
  for _, window in ipairs(hl.get_windows() or {}) do remember(window) end
  T.installed = true
end

-- Called by every widget instance (one per monitor) on start and after each
-- Hyprland reload. Installs once per Lua state; later calls are no-ops.
function T.attach()
  if not T.installed then install() end
  return reply("attached," .. T.version)
end

-- Called once by each widget instance when it starts: clear a hover highlight
-- left behind by a shell that died mid-hover, and report every parked window's
-- origin as taskbox>>origins,<address>=<workspace id>;...
function T.hello()
  local origins = {}
  for _, window in ipairs(hl.get_windows() or {}) do
    for _, tag in ipairs(window.tags or {}) do
      tag = tostring(tag)
      if tag == "taskbox-hover" then untag_hover(window.address) end
      if tag:sub(1, #ORIGIN_PREFIX) == ORIGIN_PREFIX then
        origins[#origins + 1] = window.address .. "=" .. tag:sub(#ORIGIN_PREFIX + 1)
      end
    end
  end
  return reply("origins," .. table.concat(origins, ";"))
end

------------------------------------------------------------------ actions

-- Focus without warping the cursor onto the window.
function T.focus(address)
  if not window_for(address) then return reply("missing") end
  with_config("cursor", "no_warps", true, function()
    hl.dispatch(hl.dsp.focus({ window = selector(address) }))
  end)
  return reply("focused")
end

-- Drag-to-workspace: move without following. `workspace` is an id ("13") or
-- a named workspace ("name:dev", e.g. per-monitor setups). The window never arrives
-- fullscreen, and it fits in: tiled if the workspace has tiled windows,
-- floating if it only has floating ones, unchanged if empty. Anything
-- maximized there is restored so both are visible. It's focused the next
-- time that workspace is opened (one-shot; latest drop wins).
function T.send(address, workspace)
  local target = tostring(workspace)
  local window = window_for(address)
  if not window then return reply("missing") end
  if is_target(window.workspace, target) then return reply("same") end

  local tiled, floating = 0, 0
  for _, other in ipairs(hl.get_workspace_windows(target) or {}) do
    if other.address ~= address then
      if other.floating then floating = floating + 1 else tiled = tiled + 1 end
      set_fullscreen_off(other.address, other.fullscreen)
    end
  end

  untag_hover(address)
  set_fullscreen_off(address, window.fullscreen)
  with_config("cursor", "no_warps", true, function()
    hl.dispatch(hl.dsp.window.move({ workspace = target, follow = false, window = selector(address) }))
    if tiled > 0 and window.floating then
      hl.dispatch(hl.dsp.window.float({ action = "disable", window = selector(address) }))
    elseif tiled == 0 and floating > 0 and not window.floating then
      hl.dispatch(hl.dsp.window.float({ action = "enable", window = selector(address) }))
    end
  end)

  T.arrivals[target] = address
  return reply("sent")
end

-- Minimize = park on a special workspace (same convention as a hyprbars
-- "minimize" button), without toggling that workspace into view.
function T.minimize(address, special)
  if not window_for(address) then return reply("missing") end
  untag_hover(address)
  with_config("cursor", "no_warps", true, function()
    hl.dispatch(hl.dsp.window.move({ workspace = "special:" .. special, follow = false, window = selector(address) }))
  end)
  return reply("minimized")
end

-- Restore a minimized window onto the given workspace and focus it.
function T.restore(address, workspace)
  if not window_for(address) then return reply("missing") end
  with_config("cursor", "no_warps", true, function()
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(workspace), follow = false, window = selector(address) }))
    hl.dispatch(hl.dsp.focus({ window = selector(address) }))
  end)
  return reply("restored")
end

function T.toggle_floating(address)
  if not window_for(address) then return reply("missing") end
  hl.dispatch(hl.dsp.window.float({ action = "toggle", window = selector(address) }))
  return reply("floating")
end

function T.toggle_maximized(address)
  local window = window_for(address)
  if not window then return reply("missing") end
  local action = window.fullscreen == 1 and "unset" or "set"
  hl.dispatch(hl.dsp.window.fullscreen({ mode = "maximized", action = action, window = selector(address) }))
  return reply("maximized")
end

-- Graceful close: the app may ask to save. (The widget prefers the Wayland
-- handle's close(); this covers windows that don't have one yet.)
function T.close(address)
  if not window_for(address) then return reply("missing") end
  hl.dispatch(hl.dsp.window.close({ window = selector(address) }))
  return reply("closed")
end

-- The taskbar's ×: force kill if Alt is physically held right now, else a
-- graceful close. Decided here, from the real key state, because the bar's
-- own Alt tracking (press/release events) can miss a release — and a missed
-- release must never turn a close into a SIGKILL.
function T.close_or_kill(address)
  if not window_for(address) then return reply("missing") end
  if hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R") then return T.kill(address) end
  return T.close(address)
end

-- Force kill: SIGKILL the owning process (takes all of that app's windows).
function T.kill(address)
  local window = window_for(address)
  if not window then return reply("missing") end
  local pid = tonumber(window.pid) or 0
  if pid > 1 then hl.dispatch(hl.dsp.exec_cmd("kill -9 " .. pid)) end
  return reply("killed")
end

return reply("loaded," .. T.version)
