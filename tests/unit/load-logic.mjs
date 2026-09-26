// Loads lib/Logic.js (a QML `.pragma library` script) into Node: strips the
// QML-only pragma line and evaluates the rest in its own context, exposing its
// top-level functions and vars exactly as QML sees them.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const path = fileURLToPath(new URL("../../lib/Logic.js", import.meta.url))
const source = readFileSync(path, "utf8").replace(/^\.pragma library\s*$/m, "")
const context = vm.createContext({})
vm.runInContext(source, context, { filename: path })

export default context
