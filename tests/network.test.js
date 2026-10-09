const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const qml = fs.readFileSync(path.join(__dirname, "../Panel.qml"), "utf8");
function controller(values, functions) {
  const context = vm.createContext(values);
  context.root = context;
  // Exercise the controller's production functions with observable process/timer boundaries.
  for (const name of functions) {
    const start = qml.indexOf("function " + name + "(");
    assert.ok(start >= 0, "Missing controller function: " + name);
    let end = qml.indexOf("{", start) + 1;
    let depth = 1;
    while (depth && end < qml.length) {
      if (qml[end] === "{") depth++;
      if (qml[end] === "}") depth--;
      end++;
    }
    vm.runInContext(qml.slice(start, end), context);
  }
  return context;
}
function timer() {
  return { running: false, interval: 0, starts: 0,
    restart() { this.running = true; this.starts++; },
    stop() { this.running = false; } };
}

function fixture() {
  return controller({ networkReady: false, loading: false, retries: 0, retryTimer: timer(),
    report: {cached:true}, hasCoordinates:true, configuredLocationState:{latitude:12,longitude:34},
    weatherProc:{running:false}, locationProc:{running:false}, fetchScript:"/fixture/fetch",
    locationResolverScript:"/fixture/location", requestUserAgent:"", preferencesReady:true,
    automaticLocation:true,
  }, ["refresh", "resolveLocation", "scheduleRetry"]);
}
test("offline refresh preserves cached weather and starts no remote helper", () => {
  const c = fixture(); c.refresh(true); c.resolveLocation(true);
  assert.equal(c.weatherProc.running, false); assert.equal(c.locationProc.running, false);
  assert.equal(c.report.cached, true);
});
test("forecast and location requests resume after readiness and do not overlap themselves", () => {
  const c = fixture(); c.networkReady = true; c.refresh(true); c.resolveLocation(true);
  assert.equal(c.weatherProc.running, true); assert.equal(c.locationProc.running, true);
  const command = c.weatherProc.command; c.refresh(true);
  assert.equal(c.weatherProc.command, command);
  assert.deepEqual(Array.from(command), ["/fixture/fetch", "--force"]);
  assert.equal(c.weatherProc.requestInput, "12\n34\n");
  assert.equal(c.weatherProc.stdinEnabled, true);
});
test("forecast retry bursts are bounded with increasing delays", () => {
  const c = fixture(); c.networkReady = true;
  for (const interval of [2500,5000,10000]) {c.scheduleRetry();assert.equal(c.retryTimer.interval,interval);}
  c.scheduleRetry(); assert.equal(c.retryTimer.starts,3);
  c.retries=0;c.networkReady=false;c.scheduleRetry();assert.equal(c.retryTimer.starts,3);
});

test("notification summaries keep coordinate fallback labels out of command arguments", () => {
  const calls = [];
  const c = controller({ current:{windSpeed:3,windDirection:90,humidity:50},
    configuredLocation:"12.35, -56.79",currentDescription:"Cloudy",currentTemperature:"15°C",
    conditionIcon:"cloud",tr:value=>value,windSpeed:value=>String(value),windLabel:()=>"E",
    Quickshell:{execDetached:args=>calls.push(Array.from(args))},
  }, ["notifySummary"]);
  c.notifySummary();
  assert.equal(calls[0].join(" ").includes("12.35"), false);
  assert.equal(calls[0].join(" ").includes("-56.79"), false);
  c.configuredLocation="Example Town";c.notifySummary();
  assert.equal(calls[1][3], "Været i Example Town");
});
