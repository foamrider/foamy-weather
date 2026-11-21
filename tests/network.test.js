const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const service = fs.readFileSync(path.join(__dirname, "../WeatherService.qml"), "utf8");
const Model = require("../Model.js");
const FoamyNative = require("../kit/node-loader.cjs").load("FoamyNative");
function controller(values, functions) {
  const qml = service;
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
    weatherProc:{running:false}, locationProc:{running:false}, pluginDir:"/fixture",
    helperUnavailable:false, FoamyNative, requestUserAgent:"", preferencesReady:true,
    automaticLocation:true, weatherGeneration:0, locationGeneration:0, coordinateQuery:"12,34",
    configuredLocation:"Example", errorMessage:"", errorValues:[], Model,
  }, ["refresh", "resolveLocation", "scheduleRetry", "setError", "finishWeather"]);
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
  assert.deepEqual(Array.from(command), Array.from(FoamyNative.command("/fixture", "foamy-weather-helper", ["fetch", "--force"])));
  assert.deepEqual(Array.from(c.locationProc.command).slice(-2), ["resolve-location", "--force"]);
  assert.equal(c.weatherProc.requestInput, "12\n34\n");
  assert.equal(c.weatherProc.stdinEnabled, true);
});
test("forecast retry bursts are bounded with increasing delays", () => {
  const c = fixture(); c.networkReady = true;
  for (const interval of [2500,5000,10000]) {c.scheduleRetry();assert.equal(c.retryTimer.interval,interval);}
  c.scheduleRetry(); assert.equal(c.retryTimer.starts,3);
  c.retries=0;c.networkReady=false;c.scheduleRetry();assert.equal(c.retryTimer.starts,3);
});

// A place change during a running fetch (the stopped fetch is never shown,
// no error, no retry): tests/fetch-runtime.py. The query and the coordinates
// reach the helper on stdin, never in its argv: fetch-runtime.py and
// search-runtime.py, from /proc while the helper runs.
test("a missing helper (exit 127) is reported once and nothing retries", () => {
  const c = controller({ networkReady: true, loading: true, retries: 0, retryTimer: timer(), locationRetryTimer: timer(),
    helperUnavailable: false, FoamyNative, errorMessage: "", errorValues: [], dynamicLocationError: "",
    dynamicLocationErrorValues: [], weatherProc: { running: false }, hasCoordinates: true, automaticLocation: true,
    locationProc: { running: false }, configuredLocationState: { latitude: 12, longitude: 34 }, pluginDir: "/fixture",
    requestUserAgent: "", weatherGeneration: 0, locationGeneration: 0, Model },
    ["helperExited", "setError", "refresh", "resolveLocation", "finishWeather", "scheduleRetry"]);
  assert.equal(c.helperExited(1), false);
  assert.equal(c.helperUnavailable, false);
  c.finishWeather("", 0, "12,34", "");
  assert.equal(c.retryTimer.running, true);
  assert.equal(c.helperExited(127), true);
  assert.equal(c.retryTimer.running, false);
  assert.equal(c.errorMessage, FoamyNative.UNAVAILABLE_TEXT);
  assert.equal(c.dynamicLocationError, FoamyNative.UNAVAILABLE_TEXT);
  c.refresh(true); c.resolveLocation(true);
  assert.equal(c.weatherProc.running, false); assert.equal(c.locationProc.running, false);
  c.finishWeather("", 0, "12,34", "");
  assert.equal(c.retryTimer.running, false);
  assert.equal(c.errorMessage, FoamyNative.UNAVAILABLE_TEXT);
});
