const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

test("weather uses the scoped hover setter without writing readonly state", () => {
  const source = fs.readFileSync(path.join(__dirname, "../Panel.qml"), "utf8");
  const start = source.indexOf("  function setCenterHoverRevealSuppressed(");
  const end = source.indexOf("\n  }", start) + 4;
  let value = false;
  const bar = Object.freeze({ centerHoverRevealSuppressed: false,
    setCenterHoverRevealSuppressed(next) { value = next; } });
  const context = vm.createContext({ root: { bar } });
  vm.runInContext(source.slice(start, end), context);
  context.setCenterHoverRevealSuppressed(true);
  assert.equal(value, true);
  context.setCenterHoverRevealSuppressed(false);
  assert.equal(value, false);
});
