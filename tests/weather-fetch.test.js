const assert = require("node:assert/strict");
const { execFile } = require("node:child_process");
const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { promisify } = require("node:util");
const { gzipSync } = require("node:zlib");
const test = require("node:test");
const Model = require("../Model.js");

const exec = promisify(execFile);
const script = path.join(__dirname, "../scripts/weather-fetch.sh");
const forecastLimit = 2 * 1024 * 1024;
const sunLimit = 64 * 1024;
const forecast = JSON.stringify({
  type: "Feature",
  properties: { timeseries: [{
    time: new Date().toISOString(),
    data: { instant: { details: { air_temperature: 12 } } }
  }] }
});
const sun = JSON.stringify({ properties: {
  sunrise: { time: "2026-09-27T06:00:00Z" },
  sunset: { time: "2026-09-27T18:00:00Z" }
} });

// Cache entries other than MET's Expires/Last-Modified bookkeeping.
async function files(dir) {
  return (await fs.readdir(dir)).filter(name => !name.endsWith(".meta"));
}

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "weather-fetch-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const cache = path.join(root, "cache/omarchy-weather");
  const bin = path.join(root, "bin");
  await fs.mkdir(cache, { recursive: true });
  await fs.mkdir(bin);
  const responses = { forecast: { body: forecast }, sun: { body: sun } };
  const requests = [];
  const forecastHeaders = [];
  const server = http.createServer((req, res) => {
    const kind = req.url.includes("/locationforecast/") ? "forecast" : "sun";
    requests.push(kind);
    if (kind === "forecast") forecastHeaders.push(req.headers);
    const response = responses[kind];
    if (kind === "forecast" && response.notModified && req.headers["if-modified-since"] === response.lastModified) {
      res.statusCode = 304;
      res.end();
      return;
    }
    for (const [name, value] of Object.entries(response.headers || {})) res.setHeader(name, value);
    let body = Buffer.from(response.body);
    if (response.gzip) {
      body = gzipSync(body);
      res.setHeader("Content-Encoding", "gzip");
    }
    if (response.invalidGzip) res.setHeader("Content-Encoding", "gzip");
    // flushHeaders forces chunked delivery without a Content-Length header.
    if (!response.chunked) res.setHeader("Content-Length", body.length + (response.truncated ? 100 : 0));
    res.statusCode = response.status || 200;
    res.flushHeaders();
    res.end(body);
  });
  server.keepAliveTimeout = 1;
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise(resolve => {
    server.close(resolve);
    server.closeAllConnections();
  }));

  const env = { ...process.env, XDG_CACHE_HOME: path.join(root, "cache"),
    PATH: `${bin}:${process.env.PATH}`, WEATHER_TEST_ROOT: root,
    WEATHER_TEST_ORIGIN: `http://127.0.0.1:${server.address().port}`,
    // Forced refreshes download at once unless a test asks for the minimum age.
    MET_WEATHER_FORCE_MIN_AGE: "0" };
  // Redirect only the endpoint; the production script still runs real curl,
  // decompression, byte limiting, jq, and cache promotion.
  const wrappers = {
    curl: `sed "s|https://api.met.no|$WEATHER_TEST_ORIGIN|g" |
  "$WEATHER_TEST_CURL" -q --noproxy '*' "$@"
`,
    jq: `for arg in "$@"; do
  [[ -f $arg ]] || continue
  case "$arg" in *forecast*) limit=${forecastLimit} ;; *sun*) limit=${sunLimit} ;; *) continue ;; esac
  if (( $(stat -c %s -- "$arg") > limit )); then
    printf '%s\\n' "$arg" >>"$WEATHER_TEST_ROOT/oversized-parse"
    exit 99
  fi
done
exec "$WEATHER_TEST_JQ" "$@"
`,
    rm: `# Record temporary file sizes before the production EXIT trap removes them.
for arg in "$@"; do
  [[ -f $arg ]] || continue
  printf '%s\\t%s\\n' "$(stat -c %s -- "$arg")" "$arg" >>"$WEATHER_TEST_ROOT/removed"
done
exec "$WEATHER_TEST_RM" "$@"
`
  };
  for (const [name, body] of Object.entries(wrappers)) {
    env[`WEATHER_TEST_${name.toUpperCase()}`] = (await exec("bash", ["-c", `command -v ${name}`])).stdout.trim();
    await fs.writeFile(path.join(bin, name), `#!/bin/bash\nset -euo pipefail\n${body}`, { mode: 0o755 });
  }
  const cacheKey = createHash("sha256").update("12.000_34.000").digest("hex");
  const forecastPath = path.join(cache, `forecast-complete-${cacheKey}.json`);
  return { responses, requests, forecastHeaders, cache, forecastPath, env,
    async run(force = false, extraEnv = {}) {
      const request = exec("bash", [script, ...(force ? ["--force"] : [])],
        { env: { ...env, ...extraEnv }, timeout: 15000, maxBuffer: 8 * 1024 * 1024 });
      request.child.stdin.end("12\n34\n");
      const { stdout } = await request;
      assert.equal(await fs.access(path.join(root, "oversized-parse")).then(() => true, () => false), false,
        "oversized files must never reach jq");
      const removed = await fs.readFile(path.join(root, "removed"), "utf8");
      for (const line of removed.trim().split("\n")) {
        const [size, file] = line.split("\t");
        const limit = file.includes(".forecast.") ? forecastLimit : sunLimit;
        assert.ok(Number(size) <= limit + 1, `temporary download exceeded its byte ceiling: ${line}`);
      }
      assert.equal((await fs.readdir(cache)).some(name => name.startsWith(".")), false,
        "temporary files must be cleaned up");
      return JSON.parse(stdout);
    },
    async seedSun(body) {
      for (const offset of [0, 1, 2]) {
        const date = (await exec("date", ["-d", `+${offset} day`, "+%Y-%m-%d"])).stdout.trim();
        await fs.writeFile(path.join(cache, `sun-${cacheKey}-${date}.json`), body);
      }
    }
  };
}

test("normal compressed downloads produce a usable forecast and reuse fresh caches", async t => {
  const f = await fixture(t);
  f.responses.forecast.gzip = true;
  f.responses.sun.gzip = true;
  const report = await f.run();
  assert.equal(report.stale, false);
  assert.equal(Model.currentCondition(Model.parseBundle(JSON.stringify(report))).temperature, 12);
  assert.equal(report.sun.length, 3);
  assert.ok(report.sun.every(day => day.sunrise && day.sunset));
  assert.equal(f.requests.length, 4);
  await f.run();
  assert.equal(f.requests.length, 4);
});

for (const [label, options] of Object.entries({
  "known length": {}, "chunked": { chunked: true },
  "gzip": { gzip: true }, "chunked gzip": { gzip: true, chunked: true }
})) {
  for (const kind of ["forecast", "sun"]) {
    test(`rejects oversized ${kind} with ${label} before parsing or caching`, async t => {
      const f = await fixture(t);
      const limit = kind === "forecast" ? forecastLimit : sunLimit;
      // A valid JSON prefix plus whitespace catches silent truncation acceptance.
      f.responses[kind] = { ...options, body: (kind === "forecast" ? forecast : sun) + " ".repeat(limit * 2) };
      const report = await f.run();
      if (kind === "forecast") {
        assert.ok(report.error);
        assert.deepEqual(await files(f.cache), []);
      } else {
        assert.equal(report.stale, false);
        assert.ok(report.sun.every(day => day.sunrise === "" && day.sunset === ""));
        assert.deepEqual(await files(f.cache), [path.basename(f.forecastPath)]);
      }
    });
  }
}

test("accepts the exact byte limits and rejects one byte over", async t => {
  const f = await fixture(t);
  f.responses.forecast.body = forecast.padEnd(forecastLimit);
  f.responses.sun.body = sun.padEnd(sunLimit);
  assert.equal((await f.run()).stale, false);
  const original = await fs.readFile(f.forecastPath, "utf8");
  f.responses.forecast.body += " ";
  assert.equal((await f.run(true)).stale, true);
  assert.equal(await fs.readFile(f.forecastPath, "utf8"), original);
  await f.seedSun("invalid");
  f.responses.sun.body += " ";
  assert.ok((await f.run()).sun.every(day => day.sunrise === ""));
});

for (const [label, response] of Object.entries({
  malformed: { body: "{broken" },
  "multiple JSON documents": { body: `${forecast}\n${forecast}` },
  "invalid schema": { body: '{"type":"Feature","properties":{"timeseries":"wrong"}}' },
  "HTTP failure": { body: forecast, status: 503 },
  "interrupted transfer": { body: forecast, truncated: true },
  "invalid gzip": { body: forecast, invalidGzip: true },
  "oversized gzip": { body: forecast + " ".repeat(forecastLimit * 2), gzip: true }
})) {
  test(`${label} preserves a valid forecast and reports stale data`, async t => {
    const f = await fixture(t);
    await f.run();
    const original = await fs.readFile(f.forecastPath, "utf8");
    f.responses.forecast = response;
    assert.equal((await f.run(true)).stale, true);
    assert.equal(await fs.readFile(f.forecastPath, "utf8"), original);
    await fs.unlink(f.forecastPath);
    assert.ok((await f.run()).error);
  });
}

for (const [label, response] of Object.entries({
  malformed: { body: "{broken" },
  "multiple JSON documents": { body: `${sun}\n${sun}` },
  "invalid schema": { body: '{"properties":{"sunrise":{"time":123},"sunset":{"time":true}}}' },
  "HTTP failure": { body: sun, status: 503 },
  "interrupted transfer": { body: sun, truncated: true },
  "invalid gzip": { body: sun, invalidGzip: true }
})) {
  test(`${label} sunrise response leaves the forecast usable without caching bad data`, async t => {
    const f = await fixture(t);
    f.responses.sun = response;
    const report = await f.run();
    assert.equal(report.stale, false);
    assert.ok(report.sun.every(day => day.sunrise === "" && day.sunset === ""));
    assert.deepEqual(await files(f.cache), [path.basename(f.forecastPath)]);
  });
}

for (const label of ["oversized", "malformed"]) {
  test(`${label} existing caches are rejected and can be replaced`, async t => {
    const f = await fixture(t);
    await fs.writeFile(f.forecastPath, label === "oversized" ? forecast + " ".repeat(forecastLimit) : "{broken");
    await f.seedSun(label === "oversized" ? sun + " ".repeat(sunLimit) : "{broken");
    f.responses.forecast.status = 503;
    assert.ok((await f.run()).error);
    f.responses.forecast.status = 200;
    f.responses.sun.status = 503;
    const report = await f.run();
    assert.equal(report.stale, false);
    assert.ok(report.sun.every(day => day.sunrise === "" && day.sunset === ""));
    f.responses.sun.status = 200;
    assert.ok((await f.run()).sun.every(day => day.sunrise && day.sunset));
  });
}

test("honours MET Expires, revalidates with If-Modified-Since and spaces forced refreshes", async t => {
  const f = await fixture(t);
  const lastModified = "Thu, 29 Oct 2026 10:00:00 GMT";
  f.responses.forecast.headers = { Expires: new Date(Date.now() + 3600 * 1000).toUTCString(), "Last-Modified": lastModified };
  assert.equal((await f.run()).stale, false);
  assert.equal(f.forecastHeaders.length, 1);
  // Within Expires: no request even though the fallback max age is zero.
  await f.run(false, { MET_WEATHER_CACHE_MAX_AGE: "0" });
  assert.equal(f.forecastHeaders.length, 1);
  // --force inside the minimum age reuses the cache too.
  await f.run(true, { MET_WEATHER_FORCE_MIN_AGE: "60" });
  assert.equal(f.forecastHeaders.length, 1);
  // Expired: revalidate; MET answers 304 and the cache is current again.
  const old = new Date(Date.now() - 7200 * 1000);
  await fs.utimes(f.forecastPath, old, old);
  await fs.writeFile(f.forecastPath.replace(/\.json$/, ".meta"), `${Math.floor(Date.now() / 1000) - 10}\n${lastModified}\n`);
  f.responses.forecast = { body: "", notModified: true, lastModified, headers: { Expires: new Date(Date.now() + 1800 * 1000).toUTCString() } };
  const report = await f.run();
  assert.equal(report.stale, false);
  assert.equal(f.forecastHeaders.length, 2);
  assert.equal(f.forecastHeaders[1]["if-modified-since"], lastModified);
  assert.ok(Date.now() - (await fs.stat(f.forecastPath)).mtimeMs < 60000, "a 304 refreshes the cache age");
  assert.equal(Model.currentCondition(Model.parseBundle(JSON.stringify(report))).temperature, 12);
  // A 304 without Last-Modified keeps the cached validator for the next request.
  await f.run(true);
  assert.equal(f.forecastHeaders.length, 3);
  assert.equal(f.forecastHeaders[2]["if-modified-since"], lastModified);
});

test("migrates 1.1 caches hashed from four-decimal coordinates", async t => {
  const f = await fixture(t);
  const oldKey = createHash("sha256").update("12.0000_34.0000").digest("hex");
  const oldPath = path.join(f.cache, `forecast-complete-${oldKey}.json`);
  await fs.writeFile(oldPath, forecast);
  const old = new Date(Date.now() - 3 * 3600 * 1000);
  await fs.utimes(oldPath, old, old);
  for (const offset of [0, 1, 2]) {
    const date = (await exec("date", ["-d", `+${offset} day`, "+%Y-%m-%d"])).stdout.trim();
    await fs.writeFile(path.join(f.cache, `sun-${oldKey}-${date}.json`), sun);
  }
  // MET is down after the upgrade: the old forecast is still shown, as stale data.
  f.responses.forecast.status = 503;
  f.responses.sun.status = 503;
  const report = await f.run();
  assert.equal(report.stale, true);
  assert.equal(Model.currentCondition(Model.parseBundle(JSON.stringify(report))).temperature, 12);
  assert.ok(report.sun.every(day => day.sunrise && day.sunset), "sun caches migrate too");
  assert.equal(Math.round((await fs.stat(f.forecastPath)).mtimeMs / 1000), Math.round(old.getTime() / 1000), "age preserved");
});

test("rounds forecast coordinates to three decimals and keeps them out of cache names", async t => {
  const f = await fixture(t);
  await f.run();
  const names = await fs.readdir(f.cache);
  assert.ok(names.every(name => !name.includes("12.000") && !name.includes("34.000")));
});

test("missing programs are reported with a translatable key", async t => {
  const f = await fixture(t);
  const bin = path.join(f.cache, "..", "..", "minimal-bin");
  await fs.mkdir(bin);
  for (const name of ["bash", "jq", "date", "stat", "awk", "head", "sha256sum"]) {
    await fs.symlink((await exec("bash", ["-c", `command -v ${name}`])).stdout.trim(), path.join(bin, name));
  }
  const request = exec(path.join(bin, "bash"), [script], { env: { ...f.env, PATH: bin } });
  request.child.stdin.end("12\n34\n");
  const report = JSON.parse((await request).stdout);
  assert.deepEqual(report, { error: "Missing required program: %1", values: ["curl"] });
});
