const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// The sky's vertex and fragment stages share one uniform block; Qt needs it
// identical in both (a mismatch fails to link, and the header loses its sky).
const block = file => {
  const text = fs.readFileSync(path.join(__dirname, "..", "shaders", file), "utf8")
  const match = /layout\(std140, binding = 0\) uniform buf \{([\s\S]*?)\};/.exec(text)
  assert.ok(match, `${file} has the uniform block`)
  return match[1].split("\n").map(line => line.replace(/\/\/.*$/, "").trim()).filter(Boolean)
}
assert.deepEqual(block("atmosphere.vert"), block("atmosphere.frag"))
console.log("Shader block tests passed (vertex and fragment uniform blocks match).")
