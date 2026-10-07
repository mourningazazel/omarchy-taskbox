-- Tests for hypr/taskbox.lua against tests/lua/mock_hl.lua.
-- Run from the plugin root: lua tests/lua/taskbox_spec.lua (Lua 5.5, the
-- version Hyprland 0.56 embeds), or tools/dev.sh test.

package.path = "tests/lua/?.lua;" .. package.path
local Mock = require("mock_hl")
local MODULE = "hypr/taskbox.lua"

local passed, failed = 0, {}

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then passed = passed + 1 else table.insert(failed, name .. "\n    " .. tostring(err)) end
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

local function last(list) return list[#list] end

-- Fresh Hyprland + freshly loaded module (as after a Hyprland reload).
local function setup()
  _G.Taskbox = nil
  _G.hl = Mock.new()
  local loaded = dofile(MODULE)
  return _G.hl, _G.Taskbox, loaded
end

local function reply_of(dispatcher)
  assert(dispatcher and dispatcher.kind == "event", "public functions must return an event dispatcher")
  return dispatcher.args.data
end

local function count_kind(hl, kind)
  local n = 0
  for _, d in ipairs(hl._state.dispatched) do if d.kind == kind then n = n + 1 end end
  return n
end

---------------------------------------------------------------- loading

test("loading returns a harmless event and installs nothing yet", function()
  local hl, T, loaded = setup()
  eq(reply_of(loaded), "taskbox>>loaded," .. T.version)
  eq(#hl._state.binds, 0, "binds before attach")
end)

test("attach installs 4 non-consuming Alt binds, 1 rule and the hooks, once", function()
  local hl, T = setup()
  eq(reply_of(T.attach()), "taskbox>>attached," .. T.version)
  local s = hl._state
  eq(#s.binds, 4, "binds")
  for _, b in ipairs(s.binds) do
    assert(b.key == "Alt_L" or b.key == "Alt_R", b.key)
    assert(b.opts.non_consuming and b.opts.ignore_mods, "Alt binds must not swallow Alt")
  end
  eq(#s.rules, 1, "rules")
  eq(s.rules[1].match.tag, "taskbox-hover")
  eq(s.rules[1].border_color, "rgb(d97b3f) rgb(d97b3f)")
  eq(s.rules[1].border_size, 4)
  for _, h in ipairs({ "workspace.active", "window.move_to_workspace", "window.open", "window.close" }) do
    assert(s.hooks[h] and #s.hooks[h] == 1, "hook " .. h)
  end
  -- attach from a second monitor's widget, and a re-dofile: no duplicates
  T.attach()
  dofile(MODULE)
  _G.Taskbox.attach()
  eq(#s.binds, 4, "binds after re-attach")
  eq(#s.rules, 1, "rules after re-attach")
end)

test("source never removes binds, rules or hooks", function()
  local src = assert(io.open(MODULE)):read("a")
  local code = src:gsub("%-%-[^\n]*", "")   -- ignore comments
  for _, pattern in ipairs({ ":remove%(", ":set_enabled%(", ":unbind%(", "hl%.unbind%(" }) do
    assert(not code:find(pattern), "hypr/taskbox.lua must not call " .. pattern)
  end
end)

test("active_color handles hex strings, numbers and garbage", function()
  local _, T = setup()
  eq(T.active_color({ colors = { "0xC0D97B3F" } }), "rgb(d97b3f)")
  eq(T.active_color({ colors = { 0xFF112233 } }), "rgb(112233)")
  eq(T.active_color("0x80ABCDEF"), "rgb(abcdef)")
  eq(T.active_color({ colors = {} }), "rgb(d97b3f)")
  eq(T.active_color("not a colour"), "rgb(d97b3f)")
end)

---------------------------------------------------------------- safety

test("every action on a missing window replies 'missing' and dispatches nothing", function()
  local hl, T = setup()
  T.attach()
  local before = #hl._state.dispatched
  for _, call in ipairs({
    function() return T.focus("0xdead") end,
    function() return T.send("0xdead", "3") end,
    function() return T.minimize("0xdead", "minimized") end,
    function() return T.restore("0xdead", "1") end,
    function() return T.toggle_floating("0xdead") end,
    function() return T.toggle_maximized("0xdead") end,
    function() return T.close("0xdead") end,
    function() return T.kill("0xdead") end,
  }) do
    eq(reply_of(call()), "taskbox>>missing")
  end
  eq(#hl._state.dispatched, before, "dispatches")
end)

test("temporarily overridden config is always restored", function()
  local hl, T = setup()
  T.attach()
  Mock.window("0xa", 1)
  Mock.window("0xb", 2)
  T.focus("0xa")
  T.send("0xa", "2")
  T.minimize("0xb", "minimized")
  T.restore("0xb", "1")
  hl._fire("workspace.active", { id = 2, name = "2", special = false })
  hl._run_timers()
  eq(hl._state.config["cursor.no_warps"], false, "no_warps")
  eq(hl._state.config["misc.on_focus_under_fullscreen"], 1, "on_focus_under_fullscreen")
end)

---------------------------------------------------------------- focus / close / kill

test("focus doesn't warp the cursor", function()
  local hl, T = setup()
  Mock.window("0xa", 1)
  eq(reply_of(T.focus("0xa")), "taskbox>>focused")
  eq(hl._state.focused, "0xa")
  eq(hl._state.last_focus_config.no_warps, true)
  eq(count_kind(hl, "window.alter_zorder"), 0, "tiled windows aren't raised")
end)

test("focus raises an obscured floating window and leaves it focused without warping", function()
  local hl, T = setup()
  Mock.window("0xa", 1, { floating = true })
  Mock.window("0xb", 1, { floating = true })
  eq(last(hl._state.stacking), "0xb")
  eq(reply_of(T.focus("0xa")), "taskbox>>focused")
  eq(last(hl._state.stacking), "0xa")
  eq(hl._state.focused, "0xa")
  eq(hl._state.last_focus_config.no_warps, true)
  eq(hl._state.config["cursor.no_warps"], false)
  -- Raising must still work when keyboard focus is already on the window.
  hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = "address:0xb" }))
  hl._state.focused = "0xa"
  T.focus("0xa")
  eq(last(hl._state.stacking), "0xa")
  eq(hl._state.focused, "0xa")
end)

test("close uses the window.close dispatcher", function()
  local hl, T = setup()
  T.attach()
  Mock.window("0xa", 1)
  eq(reply_of(T.close("0xa")), "taskbox>>closed")
  eq(hl._state.windows["0xa"], nil)
end)

test("kill SIGKILLs the pid, never pid 0/1", function()
  local hl, T = setup()
  Mock.window("0xa", 1, { pid = 777 })
  Mock.window("0xb", 1, { pid = 1 })
  Mock.window("0xc", 1, { pid = 0 })
  T.kill("0xa"); T.kill("0xb"); T.kill("0xc")
  eq(#hl._state.execs, 1, "exec count")
  eq(hl._state.execs[1], "kill -9 777")
end)

---------------------------------------------------------------- send (drag to workspace)

test("send: same workspace is a no-op", function()
  local hl, T = setup()
  Mock.window("0xa", 3)
  eq(reply_of(T.send("0xa", "3")), "taskbox>>same")
  eq(count_kind(hl, "window.move"), 0)
end)

test("send: never arrives maximized; tiles among tiled windows", function()
  local hl, T = setup()
  T.attach()
  local w = Mock.window("0xa", 1, { fullscreen = 1, floating = true })
  Mock.window("0xt", 2)
  eq(reply_of(T.send("0xa", "2")), "taskbox>>sent")
  eq(w.workspace.name, "2")
  eq(w.fullscreen, 0, "fullscreen")
  eq(w.floating, false, "floating")
  eq(T.arrivals["2"], "0xa")
end)

test("send: floats on a floating-only workspace", function()
  local _, T = setup()
  T.attach()
  local w = Mock.window("0xa", 1)
  Mock.window("0xf", 2, { floating = true })
  T.send("0xa", "2")
  eq(w.floating, true)
end)

test("send: keeps its state on an empty workspace", function()
  local _, T = setup()
  T.attach()
  local w = Mock.window("0xa", 1, { floating = true })
  T.send("0xa", "7")
  eq(w.floating, true)
  eq(w.workspace.name, "7")
end)

test("send: restores anything maximized on the target", function()
  local _, T = setup()
  T.attach()
  Mock.window("0xa", 1)
  local big = Mock.window("0xbig", 2, { fullscreen = 1 })
  local full = Mock.window("0xfull", 2, { fullscreen = 2 })
  T.send("0xa", "2")
  eq(big.fullscreen, 0, "maximized")
  eq(full.fullscreen, 0, "fullscreen")
end)

test("send: drops the hover highlight", function()
  local hl, T = setup()
  T.attach()
  local w = Mock.window("0xa", 1)
  hl.dispatch(hl.dsp.window.tag({ tag = "+taskbox-hover", window = "address:0xa" }))
  T.send("0xa", "2")
  assert(not has(w.tags, "taskbox-hover"))
end)

test("arrival: focuses the dropped window once, with the un-maximize focus mode", function()
  local hl, T = setup()
  T.attach()
  Mock.window("0xa", 1)
  T.send("0xa", "2")
  hl._fire("workspace.active", { id = 2, name = "2", special = false })
  hl._run_timers()
  eq(hl._state.focused, "0xa")
  eq(hl._state.last_focus_config.on_focus_under_fullscreen, 2)
  eq(T.arrivals["2"], nil, "one-shot")
  hl._state.focused = nil
  hl._fire("workspace.active", { id = 2, name = "2", special = false })
  hl._run_timers()
  eq(hl._state.focused, nil, "second visit")
end)

test("arrival: skipped if the window left that workspace meanwhile", function()
  local hl, T = setup()
  T.attach()
  local w = Mock.window("0xa", 1)
  T.send("0xa", "2")
  hl.dispatch(hl.dsp.window.move({ workspace = "5", follow = false, window = "address:0xa" }))
  hl._fire("workspace.active", { id = 2, name = "2", special = false })
  hl._run_timers()
  eq(hl._state.focused, nil)
  eq(w.workspace.name, "5")
end)

test("arrival: forgotten when the window closes (addresses get reused)", function()
  local hl, T = setup()
  T.attach()
  Mock.window("0xa", 1)
  T.send("0xa", "2")
  T.close("0xa")
  eq(T.arrivals["2"], nil)
  -- a new window reusing the address lands on 2: must not be auto-focused
  hl._open("0xa", 2)
  hl._fire("workspace.active", { id = 2, name = "2", special = false })
  hl._run_timers()
  eq(hl._state.focused, nil)
end)

---------------------------------------------------------------- minimize / origins

test("minimize parks on the special workspace and tags the origin", function()
  local hl, T = setup()
  T.attach()
  local w = hl._open("0xa", 3)
  eq(reply_of(T.minimize("0xa", "minimized")), "taskbox>>minimized")
  eq(w.workspace.name, "special:minimized")
  assert(has(w.tags, "taskbox-from-3"), "origin tag")
end)

test("minimizing from anywhere (e.g. a hyprbars button) is tagged too", function()
  local hl, T = setup()
  T.attach()
  local w = hl._open("0xa", 4)
  hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = "address:0xa" }))
  assert(has(w.tags, "taskbox-from-4"))
end)

test("windows that existed before install get origins too", function()
  local hl = Mock.new()
  _G.hl, _G.Taskbox = hl, nil
  local w = Mock.window("0xa", 6)   -- opened before Taskbox loaded
  dofile(MODULE)
  _G.Taskbox.attach()
  _G.Taskbox.minimize("0xa", "minimized")
  assert(has(w.tags, "taskbox-from-6"))
end)

test("restore moves back, focuses and clears the origin tag", function()
  local hl, T = setup()
  T.attach()
  local w = hl._open("0xa", 3)
  T.minimize("0xa", "minimized")
  eq(reply_of(T.restore("0xa", "5")), "taskbox>>restored")
  eq(w.workspace.name, "5")
  eq(hl._state.focused, "0xa")
  eq(count_kind(hl, "window.alter_zorder"), 0, "tiled windows aren't raised")
  for _, tag in ipairs(w.tags) do assert(not tag:find("^taskbox%-from%-"), tag) end
end)

test("restore brings a minimized floating window above overlapping windows", function()
  local hl, T = setup()
  T.attach()
  local w = hl._open("0xa", 3, { floating = true })
  Mock.window("0xb", 3, { floating = true })
  T.minimize("0xa", "minimized")
  eq(reply_of(T.restore("0xa", "3")), "taskbox>>restored")
  eq(w.workspace.name, "3")
  eq(last(hl._state.stacking), "0xa")
  eq(hl._state.focused, "0xa")
  eq(hl._state.last_focus_config.no_warps, true)
  eq(hl._state.config["cursor.no_warps"], false)
end)

test("re-minimizing replaces the origin tag instead of stacking", function()
  local hl, T = setup()
  T.attach()
  local w = hl._open("0xa", 3)
  T.minimize("0xa", "minimized")
  T.restore("0xa", "8")
  T.minimize("0xa", "minimized")
  local origins = 0
  for _, tag in ipairs(w.tags) do if tag:find("^taskbox%-from%-") then origins = origins + 1 end end
  eq(origins, 1)
  assert(has(w.tags, "taskbox-from-8"))
end)

test("hello reports origins and clears stale hover highlights", function()
  local hl, T = setup()
  T.attach()
  hl._open("0xa", 3)
  hl._open("0xb", 4)
  T.minimize("0xa", "minimized")
  local b = hl._state.windows["0xb"]
  hl.dispatch(hl.dsp.window.tag({ tag = "+taskbox-hover", window = "address:0xb" }))
  eq(reply_of(T.hello()), "taskbox>>origins,0xa=3")
  assert(not has(b.tags, "taskbox-hover"), "stale hover")
end)

test("closing a window forgets its last workspace", function()
  local hl, T = setup()
  T.attach()
  hl._open("0xa", 3)
  eq(T.last["0xa"], 3)
  T.close("0xa")
  eq(T.last["0xa"], nil)
end)

---------------------------------------------------------------- toggles

test("toggle_floating flips floating", function()
  local _, T = setup()
  local w = Mock.window("0xa", 1)
  T.toggle_floating("0xa"); eq(w.floating, true)
  T.toggle_floating("0xa"); eq(w.floating, false)
end)

test("toggle_maximized sets and unsets maximize", function()
  local _, T = setup()
  local w = Mock.window("0xa", 1)
  T.toggle_maximized("0xa"); eq(w.fullscreen, 1)
  T.toggle_maximized("0xa"); eq(w.fullscreen, 0)
  w.fullscreen = 2   -- real fullscreen -> maximize (not unset)
  T.toggle_maximized("0xa"); eq(w.fullscreen, 1)
end)

---------------------------------------------------------------- compatibility

test("send to a named workspace (per-monitor setups), then arrival focus", function()
  local hl, T = setup()
  T.attach()
  local w = Mock.window("0xa", 1)
  Mock.window("0xt", "dev")
  eq(reply_of(T.send("0xa", "name:dev")), "taskbox>>sent")
  eq(w.workspace.name, "dev")
  eq(reply_of(T.send("0xa", "name:dev")), "taskbox>>same")
  hl._fire("workspace.active", { id = w.workspace.id, name = "dev", special = false })
  hl._run_timers()
  eq(hl._state.focused, "0xa")
end)

test("the × force-kills only while Alt is physically down", function()
  local hl, T = setup()
  T.attach()
  Mock.window("0xa", 1, { pid = 555 })
  Mock.window("0xb", 1, { pid = 556 })
  eq(reply_of(T.close_or_kill("0xa")), "taskbox>>closed")
  eq(#hl._state.execs, 0, "no kill without Alt")
  hl._state.keys_down.Alt_R = true
  eq(reply_of(T.close_or_kill("0xb")), "taskbox>>killed")
  eq(hl._state.execs[1], "kill -9 556")
  eq(reply_of(T.close_or_kill("0xdead")), "taskbox>>missing")
end)

---------------------------------------------------------------- upcoming Hyprland

-- Hyprland after 0.56 (hyprwm/Hyprland#15831) pushes nil instead of an empty
-- object for missing windows/workspaces. Hooks and actions must shrug it off.
test("hooks tolerate nil windows and workspaces", function()
  local hl, T = setup()
  T.attach()
  local w = hl._open("0xa", 3)
  hl._fire("window.open", nil)
  hl._fire("window.close", nil)
  hl._fire("window.move_to_workspace", nil, nil)
  hl._fire("window.move_to_workspace", w, nil)
  hl._fire("workspace.active", nil)
  hl._run_timers()
  eq(T.last["0xa"], 3, "state intact")
end)

test("a window without a workspace is handled everywhere", function()
  local hl, T = setup()
  T.attach()
  local w = Mock.window("0xa", 3)
  w.workspace = nil
  hl._fire("window.open", w)
  eq(reply_of(T.send("0xa", "2")), "taskbox>>sent")
  eq(reply_of(T.minimize("0xa", "minimized")), "taskbox>>minimized")
  -- the origin tag lives on the window, so it's still reported
  w.workspace = nil
  eq(reply_of(T.hello()), "taskbox>>origins,0xa=2")
end)

---------------------------------------------------------------- report

print(string.format("%d passed, %d failed", passed, #failed))
for _, f in ipairs(failed) do print("FAIL " .. f) end
os.exit(#failed == 0 and 0 or 1)
