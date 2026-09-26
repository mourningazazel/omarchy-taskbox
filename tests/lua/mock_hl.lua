-- A strict, minimal fake of Hyprland's Lua API (`hl`), enough to run
-- hypr/taskbox.lua outside Hyprland. It simulates window state (workspace,
-- floating, fullscreen, tags, focus), fires the hooks Taskbox listens to, and
-- enforces the plugin's safety rules by *erroring*:
--   * removing a bind / disabling a rule / removing a hook (crashes 0.56)
--   * dispatching at a window selector that doesn't resolve (real Hyprland
--     would silently act on the focused window instead)
--   * leaving a temporarily overridden config value changed

local M = {}

function M.new()
  local hl = {}
  local state = {
    windows = {},          -- address -> window
    focused = nil,         -- address
    active_workspace = 1,
    config = {
      ["cursor.no_warps"] = false,
      ["misc.on_focus_under_fullscreen"] = 1,
      ["general.border_size"] = 2,
      ["general.col.active_border"] = { colors = { "0xC0D97B3F" }, angle = 0 },
    },
    dispatched = {},       -- every dispatcher, in order
    events = {},           -- hl.dsp.event payloads that were dispatched
    binds = {},
    rules = {},
    hooks = {},            -- name -> { fn, ... }
    timers = {},
    execs = {},
  }
  hl._state = state

  local function forbidden(what)
    return function() error("forbidden at runtime (crashes Hyprland 0.56): " .. what, 2) end
  end

  -- "3" → workspace 3; "name:dev" / "dev" → a named workspace (ids from 1000).
  local named, next_named_id = {}, 1000
  local function workspace_for(name)
    name = name:match("^name:(.+)$") or name
    local special = name:sub(1, 8) == "special:"
    local id = special and -(100 + #name) or tonumber(name)
    if not id then
      if not named[name] then
        named[name] = next_named_id
        next_named_id = next_named_id + 1
      end
      id = named[name]
    end
    return { id = id, name = name, special = special }
  end

  function M.window(address, ws, props)
    local w = {
      address = address,
      workspace = workspace_for(tostring(ws)),
      floating = false,
      fullscreen = 0,
      tags = {},
      pid = 4242,
      class = "app",
    }
    for k, v in pairs(props or {}) do w[k] = v end
    state.windows[address] = w
    return w
  end

  local function resolve(selector)
    if selector == nil then error("dispatch without a window selector would hit the focused window", 3) end
    local address = selector:match("^address:(.+)$")
    local w = address and state.windows[address]
    if not w then error("dispatch to a window that doesn't exist: " .. tostring(selector), 3) end
    return w
  end

  local function fire(name, ...)
    for _, fn in ipairs(state.hooks[name] or {}) do fn(...) end
  end

  local function has_tag(w, tag)
    for i, t in ipairs(w.tags) do if t == tag then return i end end
  end

  -- Dispatchers are plain tables; hl.dispatch applies them.
  local function dsp(kind) return function(args) return { kind = kind, args = args or {} } end end
  hl.dsp = {
    event = function(data) return { kind = "event", args = { data = data } } end,
    exec_cmd = function(cmd) return { kind = "exec_cmd", args = { cmd = cmd } } end,
    focus = dsp("focus"),
    window = {
      move = dsp("window.move"),
      float = dsp("window.float"),
      fullscreen = dsp("window.fullscreen"),
      tag = dsp("window.tag"),
      close = dsp("window.close"),
    },
  }

  function hl.dispatch(d)
    assert(type(d) == "table" and d.kind, "hl.dispatch expects a dispatcher")
    table.insert(state.dispatched, d)
    local a = d.args
    if d.kind == "event" then
      table.insert(state.events, a.data)
    elseif d.kind == "exec_cmd" then
      table.insert(state.execs, a.cmd)
    elseif d.kind == "focus" then
      if a.workspace then
        state.active_workspace = tonumber(a.workspace)
      else
        local w = resolve(a.window)
        state.focused = w.address
        state.last_focus_config = {
          no_warps = state.config["cursor.no_warps"],
          on_focus_under_fullscreen = state.config["misc.on_focus_under_fullscreen"],
        }
      end
    elseif d.kind == "window.move" then
      local w = resolve(a.window)
      assert(a.follow == false, "Taskbox must never follow a moved window")
      w.workspace = workspace_for(tostring(a.workspace))
      fire("window.move_to_workspace", w, w.workspace)
    elseif d.kind == "window.float" then
      local w = resolve(a.window)
      if a.action == "enable" then w.floating = true
      elseif a.action == "disable" then w.floating = false
      elseif a.action == "toggle" then w.floating = not w.floating
      else error("unknown float action " .. tostring(a.action)) end
    elseif d.kind == "window.fullscreen" then
      local w = resolve(a.window)
      local mode = ({ maximized = 1, fullscreen = 2 })[a.mode] or error("bad mode " .. tostring(a.mode))
      if a.action == "set" then w.fullscreen = mode
      elseif a.action == "unset" then w.fullscreen = 0
      else error("unknown fullscreen action " .. tostring(a.action)) end
    elseif d.kind == "window.tag" then
      local w = resolve(a.window)
      local sign, tag = a.tag:sub(1, 1), a.tag:sub(2)
      if sign == "+" then
        if not has_tag(w, tag) then table.insert(w.tags, tag) end
      elseif sign == "-" then
        local i = has_tag(w, tag)
        if i then table.remove(w.tags, i) end
      else error("tag must start with + or -") end
    elseif d.kind == "window.close" then
      local w = resolve(a.window)
      state.windows[w.address] = nil
      fire("window.close", w)
    else
      error("mock doesn't know dispatcher " .. d.kind)
    end
  end

  function hl.get_window(selector)
    local address = tostring(selector):match("^address:(.+)$")
    return address and state.windows[address] or nil
  end

  function hl.get_windows()
    local list = {}
    for _, w in pairs(state.windows) do table.insert(list, w) end
    table.sort(list, function(x, y) return x.address < y.address end)
    return list
  end

  -- Accepts an id or a "name:<name>" selector, like Hyprland.
  function hl.get_workspace_windows(selector)
    selector = tostring(selector)
    local name = selector:match("^name:(.+)$") or selector
    local list = {}
    for _, w in ipairs(hl.get_windows()) do
      if w.workspace and w.workspace.name == name then table.insert(list, w) end
    end
    return list
  end

  state.keys_down = {}
  function hl.is_key_down(key) return state.keys_down[key] == true end

  function hl.get_config(key) return state.config[key] end

  function hl.config(tbl)
    for section, values in pairs(tbl) do
      for key, value in pairs(values) do state.config[section .. "." .. key] = value end
    end
  end

  function hl.bind(key, dispatcher, opts)
    local b = { key = key, dispatcher = dispatcher, opts = opts or {} }
    table.insert(state.binds, b)
    return { remove = forbidden("bind:remove()"), set_enabled = forbidden("bind:set_enabled()"), unbind = forbidden("bind:unbind()") }
  end

  function hl.unbind() error("forbidden at runtime: hl.unbind", 2) end

  function hl.window_rule(spec)
    table.insert(state.rules, spec)
    return { set_enabled = forbidden("rule:set_enabled()") }
  end

  function hl.on(name, fn)
    state.hooks[name] = state.hooks[name] or {}
    table.insert(state.hooks[name], fn)
    return { remove = forbidden("hook:remove()") }
  end

  function hl.timer(fn, opts)
    table.insert(state.timers, { fn = fn, opts = opts })
    return {}
  end

  -- Test helpers (not part of Hyprland's API)
  function hl._run_timers()
    local pending = state.timers
    state.timers = {}
    for _, t in ipairs(pending) do t.fn() end
  end

  function hl._fire(name, ...) fire(name, ...) end

  function hl._open(address, ws, props)
    local w = M.window(address, ws, props)
    fire("window.open", w)
    return w
  end

  return hl
end

return M
