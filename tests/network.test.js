const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const sources = {
  service: fs.readFileSync(path.join(__dirname, "../WeatherService.qml"), "utf8"),
  panel: fs.readFileSync(path.join(__dirname, "../Panel.qml"), "utf8")
};
const Model = require("../Model.js");
const FoamyNative = require("../kit/node-loader.cjs").load("FoamyNative");
function controller(values, functions, file = "service") {
  const qml = sources[file];
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

test("notification summaries keep coordinate fallback labels out of command arguments", () => {
  const calls = [];
  const c = controller({ current:{windSpeed:3,windDirection:90,humidity:50},
    reportLocation:"12.35, -56.79",currentDescription:"Cloudy",currentTemperature:"15°C",units:"metric",
    conditionIcon:"cloud",windLabel:()=>"E",Preferences:require("../Preferences.js"),
    FoamyI18n:{t:(key,values)=>values?key.replace("%1",values[0]):key,number:String},
    Quickshell:{execDetached:args=>calls.push(Array.from(args))},
  }, ["notifySummary"], "panel");
  c.notifySummary();
  assert.equal(calls[0].join(" ").includes("12.35"), false);
  assert.equal(calls[0].join(" ").includes("-56.79"), false);
  c.reportLocation="Example Town";c.notifySummary();
  assert.equal(calls[1][3], "Weather in Example Town");
});

const bundle = JSON.stringify({ forecast: { properties: { timeseries: [{ time: "2026-10-30T09:00:00Z",
  data: { instant: { details: { air_temperature: 7 } } } }] } }, sun: [], fetchedAt: "2026-10-30T09:00:00Z" });

test("a report is tagged with the place it was fetched for", () => {
  const c = fixture(); c.networkReady = true; c.report = null;
  c.finishWeather(bundle, 0, "12,34", "Example");
  assert.equal(c.report.query, "12,34"); assert.equal(c.report.locationName, "Example");
  assert.equal(c.errorMessage, ""); assert.equal(c.loading, false);
});

test("a fetch for a previous location is ignored and keeps the shown report", () => {
  const c = fixture(); c.networkReady = true;
  c.finishWeather(bundle, 0, "12,34", "Old Town");
  const shown = c.report;
  c.weatherGeneration = 1; c.loading = true;
  // A killed or late run may finish with partial output: no error, no retry.
  c.finishWeather("{\"partial", 0, "12,34", "Old Town");
  assert.equal(c.report, shown); assert.equal(c.errorMessage, "");
  assert.equal(c.retryTimer.starts, 0); assert.equal(c.loading, false);
});

test("helper errors keep their key and values for translation", () => {
  const c = fixture(); c.networkReady = true;
  c.finishWeather(JSON.stringify({ error: "Unknown option: %1", values: ["--bogus"] }), 0, "12,34", "");
  assert.equal(c.errorMessage, "Unknown option: %1");
  assert.deepEqual(Array.from(c.errorValues), ["--bogus"]);
});

// A coordinate change during a running fetch: tests/fetch-runtime.py. The
// helper's argv (no query, no coordinates): fetch-runtime.py and
// search-runtime.py, from /proc while the helper runs.
test("the geocoder query goes to the helper on stdin", () => {
  const c = controller({ editingLocation:true, automaticLocation:false, geocodePendingQuery:"Bø i Telemark",
    geocodeActiveQuery:"", geocodeGeneration:3, geocodeProc:{running:false}, geocodeLanguage:()=>"no" }, ["startGeocode"], "panel");
  c.startGeocode();
  assert.equal(c.geocodeProc.running, true); assert.equal(c.geocodeProc.stdinEnabled, true);
  assert.equal(c.geocodeProc.generation, 3, "the run carries the search generation");
  assert.deepEqual(JSON.parse(c.geocodeProc.requestInput), { query: "Bø i Telemark", language: "no" });
  assert.ok(c.geocodeProc.requestInput.endsWith("\n"));
});

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
