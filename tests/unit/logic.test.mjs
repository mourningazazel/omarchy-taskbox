// Unit tests for lib/Logic.js. Run: node --test "tests/unit/*.test.mjs" (or tools/dev.sh test)
import { test, describe } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtempSync, writeFileSync, existsSync, rmSync, chmodSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import L from "./load-logic.mjs"

// vm-context arrays/objects have a different prototype; compare as JSON.
const same = (actual, expected, ...msg) =>
  assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), expected, ...msg)

const LUA = process.env.LUA || "lua"
const bash = (script) => execFileSync("bash", ["-c", script], { encoding: "utf8" })

describe("settings", () => {
  test("defaults when empty", () => {
    same(L.normalizeSettings({}), {
      maxWidth: 200, minWidth: 44, showTitle: true, closeButton: "hover",
      middleClickClose: true, clickToMinimize: true, showMinimized: true, minimizeWorkspace: "minimized",
    })
    same(L.normalizeSettings(undefined), JSON.parse(JSON.stringify(L.normalizeSettings({}))))
  })

  test("accepts strings from `omarchy bar set` without --json", () => {
    const s = L.normalizeSettings({ maxWidth: "220", minWidth: "100", showTitle: "false", clickToMinimize: "true" })
    assert.equal(s.maxWidth, 220)
    assert.equal(s.minWidth, 100)
    assert.equal(s.showTitle, false)
    assert.equal(s.clickToMinimize, true)
  })

  test("clamps widths and keeps minWidth <= maxWidth", () => {
    const s = L.normalizeSettings({ maxWidth: 5, minWidth: 999 })
    assert.equal(s.maxWidth, 24)
    assert.equal(s.minWidth, 24)
    assert.equal(L.normalizeSettings({ maxWidth: 100000 }).maxWidth, 2000)
    assert.equal(L.normalizeSettings({ maxWidth: 150, minWidth: 300 }).minWidth, 150)
  })

  test("garbage falls back to defaults", () => {
    const s = L.normalizeSettings({ maxWidth: "wide", minWidth: null, showTitle: "yes", closeButton: "sometimes" })
    assert.equal(s.maxWidth, 200)
    assert.equal(s.minWidth, 44)
    assert.equal(s.showTitle, true)
    assert.equal(s.closeButton, "hover")
  })

  test("minimize workspace is sanitised (it goes into a Hyprland selector)", () => {
    assert.equal(L.normalizeSettings({ minimizeWorkspace: "special:parked" }).minimizeWorkspace, "parked")
    for (const bad of ["a\"); os.exit()--", "has space", "", "x".repeat(65), "new\nline"])
      assert.equal(L.normalizeSettings({ minimizeWorkspace: bad }).minimizeWorkspace, "minimized", bad)
  })
})

describe("quoting", () => {
  test("shellQuote round-trips through bash", () => {
    for (const s of ["plain", "it's", "a 'b' c", "$HOME `x` \\ \"q\"", "multi\nline", ""])
      assert.equal(bash("printf %s " + L.shellQuote(s)), s)
  })

  test("luaString produces a valid, exact Lua literal", () => {
    for (const s of ["plain", "q\"uote", "back\\slash", "new\nline", "cr\rx", "/path/with 'single'"]) {
      const out = execFileSync(LUA, ["-e", "io.write(" + L.luaString(s) + ")"], { encoding: "utf8" })
      assert.equal(out, s)
    }
  })

  test("luaCall quotes every argument and rejects odd function names", () => {
    assert.equal(L.luaCall("send", ["0xabc", "3"]), 'Taskbox.send("0xabc", "3")')
    assert.equal(L.luaCall("hello", []), "Taskbox.hello()")
    assert.throws(() => L.luaCall("os.execute", []))
    assert.throws(() => L.luaCall("x); os.exit(", []))
  })

  test("dispatchCommand shell-quotes the expression", () => {
    const cmd = L.dispatchCommand(L.luaCall("focus", ["0xabc"]))
    assert.equal(cmd, "hyprctl dispatch 'Taskbox.focus(\"0xabc\")' >/dev/null 2>&1")
  })
})

describe("addresses", () => {
  test("hexAddress/addressKey normalise prefix and case", () => {
    assert.equal(L.hexAddress("AAAB2b10"), "0xaaab2b10")
    assert.equal(L.hexAddress("0xAAAB2b10"), "0xaaab2b10")
    assert.equal(L.addressKey("0xAAAB2b10"), "aaab2b10")
    assert.equal(L.addressKey("aaab2b10"), "aaab2b10")
  })
})

describe("events", () => {
  test("recognises Taskbox events", () => {
    same(L.parseEvent("custom", "taskbox-alt>>1"), { type: "alt", held: true })
    same(L.parseEvent("custom", "taskbox-alt>>0"), { type: "alt", held: false })
    same(L.parseEvent("custom", "taskbox>>attached,1.2.3"), { type: "attached", version: "1.2.3" })
    same(L.parseEvent("configreloaded", ""), { type: "reloaded" })
    same(L.parseEvent("custom", "taskbox>>origins,0xAB=3;cd=10"), { type: "origins", origins: { ab: 3, cd: 10 } })
  })

  test("ignores everything else", () => {
    for (const [n, d] of [["custom", "something"], ["activewindow", "x"], ["custom", "taskbox>>sent"], ["custom", "taskbox-alt>>2"]])
      assert.equal(L.parseEvent(n, d), null)
  })

  test("parseOrigins skips malformed pairs", () => {
    same(L.parseOrigins(""), {})
    same(L.parseOrigins("a=1;;b;c=x;d=-2;e=1.5;=4;f=7"), { a: 1, f: 7 })
  })
})

describe("window model", () => {
  const rec = (key, workspaceId, workspaceName, activated = false) =>
    ({ key, workspaceId, workspaceName: workspaceName ?? String(workspaceId), activated })

  test("ordered: first-seen order, stable across calls", () => {
    const st = L.newState()
    same(L.ordered([rec("a", 1), rec("b", 1)], st).map((r) => r.key), ["a", "b"])
    // new window goes to the right even if listed first
    same(L.ordered([rec("c", 1), rec("a", 1), rec("b", 1)], st).map((r) => r.key), ["a", "b", "c"])
  })

  test("prune forgets closed windows so a reused address starts fresh", () => {
    const st = L.newState()
    L.ordered([rec("a", 1), rec("b", 1)], st)
    st.origin.a = 1
    L.prune(st, ["b"])
    assert.equal(st.seq.a, undefined)
    assert.equal(st.origin.a, undefined)
    // "a" comes back (address reuse): it is now the newest, i.e. rightmost
    same(L.ordered([rec("a", 1), rec("b", 1)], st).map((r) => r.key), ["b", "a"])
  })

  test("minimizedFor: shows parked windows on their origin workspace only", () => {
    const st = L.newState()
    L.minimizedFor([rec("w1", 3), rec("w2", 5)], st, 3, "minimized", true)
    const parked = [rec("w1", -99, "special:minimized"), rec("w2", -99, "special:minimized")]
    same(L.minimizedFor(parked, st, 3, "minimized", true).map((r) => r.key), ["w1"])
    same(L.minimizedFor(parked, st, 5, "minimized", true).map((r) => r.key), ["w2"])
  })

  test("minimizedFor: unknown origin shows everywhere; other special workspaces never", () => {
    const st = L.newState()
    const parked = [rec("x", -99, "special:minimized"), rec("s", -98, "special:scratchpad")]
    same(L.minimizedFor(parked, st, 1, "minimized", true).map((r) => r.key), ["x"])
    same(L.minimizedFor(parked, st, 7, "minimized", true).map((r) => r.key), ["x"])
  })

  test("minimizedFor: honours showMinimized and a custom workspace name", () => {
    const st = L.newState()
    const parked = [rec("x", -99, "special:parked")]
    same(L.minimizedFor(parked, st, 1, "parked", false), [])
    same(L.minimizedFor(parked, st, 1, "parked", true).map((r) => r.key), ["x"])
    same(L.minimizedFor(parked, st, 1, "minimized", true), [])
  })

  test("minimize conventions of other tools count as minimized", () => {
    same(L.minimizeWorkspaces("minimized"), ["minimized", "omarchy-minimized"])
    same(L.minimizeWorkspaces("parked"), ["parked", "minimized", "omarchy-minimized"])
    assert.equal(L.isMinimizedWorkspace("special:omarchy-minimized", "minimized"), true)  // window-shelf, qol-desktop-plus
    assert.equal(L.isMinimizedWorkspace("special:minimized", "parked"), true)             // hyprbars, omadock
    assert.equal(L.isMinimizedWorkspace("special:reprieve", "minimized"), false)          // hidden ≠ minimized
    assert.equal(L.isMinimizedWorkspace("special:scratchpad", "minimized"), false)
    assert.equal(L.isMinimizedWorkspace("minimized", "minimized"), false)                 // a regular workspace named so
    const st = L.newState()
    same(L.minimizedFor([rec("q", -99, "special:omarchy-minimized")], st, 1, "minimized", true).map((r) => r.key), ["q"])
  })

  test("minimizedFor: origins from Hyprland tags are respected", () => {
    const st = L.newState()
    Object.assign(st.origin, L.parseOrigins("0xAA=4"))
    const parked = [rec("aa", -99, "special:minimized")]
    same(L.minimizedFor(parked, st, 1, "minimized", true), [])
    same(L.minimizedFor(parked, st, 4, "minimized", true).map((r) => r.key), ["aa"])
  })
})

describe("layout", () => {
  const lay = (count, available, min = 44, max = 200) => L.layout(count, available, min, max, 30, 4)

  test("empty", () => same(lay(0, 500), { fitCount: 0, overflowing: false, buttonExtent: 200 }))

  test("few windows use the full default width", () => {
    same(lay(2, 1000), { fitCount: 2, overflowing: false, buttonExtent: 200 })
  })

  test("buttons shrink evenly to fill the space", () => {
    const r = lay(5, 504)            // (504 - 4*4) / 5 = 97.6
    same(r, { fitCount: 5, overflowing: false, buttonExtent: 97 })
    assert.ok(5 * r.buttonExtent + 4 * 4 <= 504)
  })

  test("overflow keeps everything inside the available space", () => {
    for (let count = 1; count <= 40; count++) {
      for (const available of [24, 44, 100, 333, 640, 1200]) {
        const r = lay(count, available)
        assert.ok(r.fitCount >= 1 && r.fitCount <= count, `fit ${count}/${available}`)
        assert.ok(r.buttonExtent >= 44 && r.buttonExtent <= 200)
        assert.equal(r.overflowing, r.fitCount < count)
        const used = L.contentExtent(r.fitCount, r.buttonExtent, r.overflowing, 30, 4, 0)
        // Only a single forced button (fit=1) may exceed a tiny space.
        if (r.fitCount > 1) assert.ok(used <= available, `used ${used} > ${available} (count ${count})`)
      }
    }
  })

  test("contentExtent", () => {
    assert.equal(L.contentExtent(0, 100, false, 30, 4, 8), 0)
    assert.equal(L.contentExtent(3, 100, false, 30, 4, 8), 3 * 100 + 2 * 4 + 8)
    assert.equal(L.contentExtent(3, 100, true, 30, 4, 8), 3 * 100 + 2 * 4 + 34 + 8)
  })

  test("pickShown keeps the focused window visible", () => {
    const items = ["a", "b", "c", "d", "e"]
    same(L.pickShown(items, 5, () => false), { shown: items, hidden: [] })
    same(L.pickShown(items, 3, (x) => x === "e"), { shown: ["a", "b", "e"], hidden: ["c", "d"] })
    same(L.pickShown(items, 3, (x) => x === "b"), { shown: ["a", "b", "c"], hidden: ["d", "e"] })
    same(L.pickShown(items, 3, () => false), { shown: ["a", "b", "c"], hidden: ["d", "e"] })
  })

  test("freeSpace: bar minus other modules, never below the minimum", () => {
    const slots = [
      { region: "left", far: 140 },
      { region: "right", length: 300 },
      { region: "right", length: 27 },
    ]
    // 1280 - 8 margin - 327 right - 140 left edge - 8 gap - 12 pad
    assert.equal(L.freeSpace(1280, slots, 8, 8, 12, 44), 785)
    assert.equal(L.freeSpace(400, slots, 8, 8, 12, 44), 44)
    assert.equal(L.freeSpace(1280, [], 8, 8, 12, 44), 1280 - 8 - 8 - 8 - 12)
  })
})

describe("interaction", () => {
  test("clickAction", () => {
    assert.equal(L.clickAction(true, false, true, true), "restore")
    assert.equal(L.clickAction(true, false, true, false), "none")
    assert.equal(L.clickAction(false, true, true, true), "minimize")
    assert.equal(L.clickAction(false, true, false, true), "focus")
    assert.equal(L.clickAction(false, true, true, false), "focus")
    assert.equal(L.clickAction(false, false, true, true), "focus")
  })

  test("workspaceChoices: 1-10 plus existing, sorted, no junk", () => {
    same(L.workspaceChoices([]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    same(L.workspaceChoices([3, 12, -99, 0, 11, 12, 2.5]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    assert.equal(L.workspaceLabel(10), "0")
    assert.equal(L.workspaceLabel(4), "4")
    assert.equal(L.workspaceLabel(12), "12")
  })
})

describe("drop targets (any workspaces widget)", () => {
  test("Omarchy's own widget: modelData is the workspace id", () => {
    assert.equal(L.dropTargetOf({ modelData: 3, workspace: null }), "3")
  })

  test("the real Hyprland workspace wins over the displayed number", () => {
    // per-monitor setups: button "3" on the second monitor is workspace 13
    assert.equal(L.dropTargetOf({ modelData: 3, workspace: { id: 13, name: "13" } }), "13")
  })

  test("decent-workspaces style: workspaceId property", () => {
    assert.equal(L.dropTargetOf({ workspaceId: 7, modelData: 7 }), "7")
  })

  test("woogy7 style: modelData object with an id", () => {
    assert.equal(L.dropTargetOf({ modelData: { id: 5, workspace: null } }), "5")
    assert.equal(L.dropTargetOf({ modelData: { workspace: { id: 12 } } }), "12")
  })

  test("per-monitor-workspaces style: named workspaces", () => {
    assert.equal(L.dropTargetOf({ modelData: { name: "DP-1:3", label: "3" } }), "")          // unsafe chars
    assert.equal(L.dropTargetOf({ modelData: { name: "dev", label: "dev" } }), "name:dev")
    assert.equal(L.dropTargetOf({ modelData: { name: "4", label: "4" } }), "4")
    assert.equal(L.dropTargetOf({ modelData: { name: "special:magic" } }), "")
  })

  test("nothing usable → no target", () => {
    for (const d of [null, {}, { modelData: "x" }, { modelData: -99 }, { modelData: 2.5 }, { workspace: { id: -98 } }])
      assert.equal(L.dropTargetOf(d), "", JSON.stringify(d))
  })

  test("sameWorkspace compares ids or names", () => {
    assert.equal(L.sameWorkspace("3", 3, "3"), true)
    assert.equal(L.sameWorkspace("4", 3, "3"), false)
    assert.equal(L.sameWorkspace("name:dev", 12, "dev"), true)
    assert.equal(L.sameWorkspace("name:dev", 12, "web"), false)
    assert.equal(L.sameWorkspace("", 3, "3"), false)
  })
})

describe("icons", () => {
  test("candidates, most specific first, no duplicates", () => {
    same(L.iconCandidates("org.gnome.Nautilus", "org.gnome.Nautilus"),
      ["org.gnome.Nautilus", "org.gnome.nautilus", "nautilus"])
    same(L.iconCandidates("foot", ""), ["foot"])
    same(L.iconCandidates("steam_app_1234", "steam_app_1234"), ["steam_app_1234", "steam"])
    same(L.iconCandidates("", ""), [])
  })

  test("web app windows are matched by host, not the browser name", () => {
    assert.equal(L.webAppHost("chrome-discord.com__channels_@me-Default"), "discord.com")
    assert.equal(L.webAppHost("chrome-web.whatsapp.com__-Default"), "web.whatsapp.com")
    assert.equal(L.webAppHost("brave-app.example.org__-Profile_1"), "app.example.org")
    assert.equal(L.webAppHost("chromium"), "")
    assert.equal(L.webAppHost("org.chromium.Chromium"), "")
    same(L.iconCandidates("chrome-discord.com__channels_@me-Default", ""),
      ["chrome-discord.com__channels_@me-Default"])
  })

  test("urlHost reads the Exec line", () => {
    assert.equal(L.urlHost("omarchy-launch-webapp https://discord.com/channels/@me"), "discord.com")
    assert.equal(L.urlHost("chromium --app=\"HTTPS://Mail.Example.com/x\""), "mail.example.com")
    assert.equal(L.urlHost("nautilus --new-window"), "")
  })
})

describe("commands", () => {
  test("hoverCommand untags the previous and tags the next", () => {
    assert.equal(L.hoverCommand("", ""), "")
    const both = L.hoverCommand("AAA", "0xbbb")
    assert.match(both, /-taskbox-hover.*address:0xaaa.*; .*\+taskbox-hover.*address:0xbbb/)
  })

  test("cleanupCommand wraps the script in flock, detached", () => {
    const cmd = L.cleanupCommand("mourningazazel.taskbox")
    assert.match(cmd, /^flock -n "\$\{XDG_RUNTIME_DIR:-\/tmp\}\/taskbox-cleanup\.lock" sh -c '/)
    assert.match(cmd, /&$/)
    bash("sh -n -c " + L.shellQuote(L.cleanupScript("x")))
  })

  // Run the real cleanup script against stub omarchy-shell / hyprctl.
  function runCleanup(listOutput, listStatus = 0) {
    const dir = mkdtempSync(join(tmpdir(), "taskbox-cleanup-"))
    const stub = (name, body) => { writeFileSync(join(dir, name), "#!/bin/sh\n" + body + "\n"); chmodSync(join(dir, name), 0o755) }
    writeFileSync(join(dir, "list.json"), listOutput)
    stub("omarchy-shell", `cat "${dir}/list.json"; exit ${listStatus}`)
    stub("hyprctl", `touch "${dir}/reloaded"`)
    try {
      execFileSync("sh", ["-c", L.cleanupScript("mourningazazel.taskbox")], {
        env: { ...process.env, PATH: dir + ":" + process.env.PATH, TASKBOX_CLEANUP_DELAY: "0" },
      })
    } catch (_) { /* the script may exit non-zero on its no-op paths */ }
    const reloaded = existsSync(join(dir, "reloaded"))
    rmSync(dir, { recursive: true })
    return reloaded
  }

  const entry = (enabled) => JSON.stringify([{ id: "omarchy.clock", enabled: true }, { id: "mourningazazel.taskbox", enabled }])

  test("cleanup: still enabled (restart, monitor change, tray/drawer host) → no reload", () => {
    assert.equal(runCleanup(entry(true)), false)
  })
  test("cleanup: disabled → reload", () => {
    assert.equal(runCleanup(entry(false)), true)
  })
  test("cleanup: removed entirely → reload", () => {
    assert.equal(runCleanup(JSON.stringify([{ id: "omarchy.clock", enabled: true }])), true)
  })
  test("cleanup: shell not answering / garbage → no reload", () => {
    assert.equal(runCleanup("", 1), false)
    assert.equal(runCleanup(""), false)
    assert.equal(runCleanup("not json"), false)
  })

  test("saveSettingCommand stores booleans/numbers as JSON", () => {
    assert.match(L.saveSettingCommand("id", "maxWidth", 220), /'maxWidth' '220' --json/)
    assert.match(L.saveSettingCommand("id", "showTitle", false), /'showTitle' 'false' --json/)
    assert.doesNotMatch(L.saveSettingCommand("id", "closeButton", "always"), /--json/)
  })
})
