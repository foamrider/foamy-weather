// The forecast helper as a process (tests/fakenet.py: bin/<arch>/
// foamy-weather-helper, FOAMY_HELPER overrides it) against a loopback HTTPS
// stand-in for MET Norway. Nothing is sent to api.met.no: the helper connects
// to FOAMY_WEATHER_TEST_CONNECT and trusts the throwaway CA through
// SSL_CERT_FILE.
const assert = require("node:assert/strict");
const { execFile, execFileSync, spawn } = require("node:child_process");
const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const https = require("node:https");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { promisify } = require("node:util");
const { gzipSync } = require("node:zlib");
const test = require("node:test");
const Model = require("../Model.js");

const exec = promisify(execFile);
const fakenet = path.join(__dirname, "fakenet.py");
const helper = execFileSync("python3", [fakenet, "argv", "fetch"], { encoding: "utf8" }).split("\0").slice(0, -1);
const proxyVariables = ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY", "SSL_CERT_DIR"];
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
  await fs.mkdir(cache, { recursive: true });
  const tls = path.join(root, "tls");
  execFileSync("python3", [fakenet, "certs", tls]);
  const responses = { forecast: { body: forecast }, sun: { body: sun } };
  const requests = [];
  const forecastHeaders = [];
  const server = https.createServer({
    key: await fs.readFile(path.join(tls, "server.key")),
    cert: await fs.readFile(path.join(tls, "server.pem"))
  }, (req, res) => {
    const kind = req.url.includes("/locationforecast/") ? "forecast" : "sun";
    requests.push(kind);
    if (kind === "forecast") forecastHeaders.push(req.headers);
    const response = responses[kind];
    if (response.handle) {
      response.handle(req, res);
      return;
    }
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

  const port = server.address().port;
  const env = { ...process.env, XDG_CACHE_HOME: path.join(root, "cache"),
    FOAMY_WEATHER_TEST_CONNECT: `127.0.0.1:${port}`,
    SSL_CERT_FILE: path.join(tls, "ca.pem"),
    // Forced refreshes download at once unless a test asks for the minimum age.
    MET_WEATHER_FORCE_MIN_AGE: "0" };
  for (const name of proxyVariables) delete env[name];
  const cacheKey = createHash("sha256").update("12.000_34.000").digest("hex");
  const forecastPath = path.join(cache, `forecast-complete-${cacheKey}.json`);
  return { responses, requests, forecastHeaders, cache, forecastPath, env, port,
    async run(force = false, extraEnv = {}) {
      const request = exec(helper[0], [...helper.slice(1), ...(force ? ["--force"] : [])],
        { env: { ...env, ...extraEnv }, timeout: 25000, maxBuffer: 8 * 1024 * 1024 });
      request.child.stdin.end("12\n34\n");
      const { stdout } = await request;
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

test("a 304 carrying Content-Encoding renews the cache without decoding", async t => {
  const f = await fixture(t);
  const lastModified = "Thu, 29 Oct 2026 10:00:00 GMT";
  f.responses.forecast.headers = { "Last-Modified": lastModified };
  assert.equal((await f.run()).stale, false);
  const metaPath = f.forecastPath.replace(/\.json$/, ".meta");
  const old = new Date(Date.now() - 7200 * 1000);
  await fs.utimes(f.forecastPath, old, old);
  await fs.writeFile(metaPath, `${Math.floor(Date.now() / 1000) - 10}\n${lastModified}\n`);
  const expires = Math.floor(Date.now() / 1000) + 1800;
  // Content-Encoding (and Content-Length) describe the representation; a 304 has no body.
  f.responses.forecast = { handle(req, res) {
    assert.equal(req.headers["if-modified-since"], lastModified);
    res.writeHead(304, { "Content-Encoding": "gzip", "Content-Length": "1234",
      Expires: new Date(expires * 1000).toUTCString(), "Last-Modified": lastModified });
    res.end();
  } };
  const report = await f.run();
  assert.equal(report.stale, false);
  assert.ok(Date.now() - (await fs.stat(f.forecastPath)).mtimeMs < 60000, "a 304 refreshes the cache age");
  assert.equal(await fs.readFile(metaPath, "utf8"), `${expires}\n${lastModified}\n`);
  assert.equal(Model.currentCondition(Model.parseBundle(JSON.stringify(report))).temperature, 12);
});

test("an empty 200 with Content-Encoding is an empty body, as with curl, and a failed refresh", async t => {
  const f = await fixture(t);
  assert.equal((await f.run()).stale, false);
  const cached = await fs.readFile(f.forecastPath, "utf8");
  for (const headers of [{ "Content-Length": "0" }, { "Transfer-Encoding": "chunked" }]) {
    f.responses.forecast = { handle(req, res) {
      res.writeHead(200, { "Content-Encoding": "gzip", ...headers });
      res.end();
    } };
    assert.equal((await f.run(true)).stale, true);
    assert.equal(await fs.readFile(f.forecastPath, "utf8"), cached);
  }
});

test("an address that drops connection attempts costs one Happy Eyeballs delay, not the budget", async t => {
  const f = await fixture(t);
  const blackhole = spawn("python3", [fakenet, "blackhole"], { stdio: ["pipe", "pipe", "inherit"] });
  t.after(() => blackhole.kill());
  const port = await new Promise((resolve, reject) => {
    blackhole.once("error", reject);
    blackhole.stdout.once("data", data => resolve(Number(String(data).trim())));
  });
  assert.ok(port > 0);
  const started = Date.now();
  const report = await f.run(false, { FOAMY_WEATHER_TEST_CONNECT: `127.0.0.1:${port},127.0.0.1:${f.port}` });
  const elapsed = Date.now() - started;
  assert.equal(report.stale, false);
  assert.ok(report.sun.every(day => day.sunrise && day.sunset));
  assert.equal(f.requests.length, 4);
  // Four requests, each 200 ms behind the dropped address; one request's
  // connect budget is 3 s, which the old serial connect spent on the first.
  assert.ok(elapsed < 3000, `took ${elapsed} ms`);
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

test("the forecast needs no other program", async t => {
  const f = await fixture(t);
  const report = await f.run(false, { PATH: "" });
  assert.equal(report.stale, false);
  assert.ok(report.sun.every(day => day.sunrise && day.sunset));
});

test("a forecast trickled byte by byte ends at the 10 s deadline", async t => {
  const f = await fixture(t);
  const timers = [];
  t.after(() => timers.forEach(clearInterval));
  f.responses.forecast = { handle(req, res) {
    res.writeHead(200, { "Content-Length": String(forecast.length) });
    let sent = 0;
    const timer = setInterval(() => {
      if (res.destroyed || sent >= forecast.length - 1) return clearInterval(timer);
      res.write(forecast[sent++]);
    }, 200);
    timers.push(timer);
  } };
  const started = Date.now();
  const report = await f.run();
  const elapsed = Date.now() - started;
  assert.deepEqual(report, { error: "Weather data is unavailable", values: [] });
  assert.ok(elapsed >= 9000 && elapsed < 14000, `took ${elapsed} ms`);
  assert.deepEqual(await files(f.cache), []);
});

async function connectProxy(t, port) {
  const connects = [];
  const proxy = http.createServer((req, res) => { res.statusCode = 405; res.end(); });
  proxy.on("connect", (req, socket, head) => {
    connects.push({ target: req.url, authorization: req.headers["proxy-authorization"] || "" });
    // Every tunnel ends at the loopback stand-in, whatever the target.
    const upstream = net.connect(port, "127.0.0.1", () => {
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  await new Promise(resolve => proxy.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise(resolve => { proxy.close(resolve); proxy.closeAllConnections(); }));
  return { connects, url: `http://127.0.0.1:${proxy.address().port}` };
}

test("https_proxy tunnels the requests through CONNECT and no_proxy bypasses it", async t => {
  const f = await fixture(t);
  const proxy = await connectProxy(t, f.port);
  const report = await f.run(true, { https_proxy: proxy.url });
  assert.equal(report.stale, false);
  assert.equal(report.sun.length, 3);
  assert.equal(proxy.connects.length, 4);
  const before = f.requests.length;
  await f.run(true, { https_proxy: proxy.url, no_proxy: "example.org, .met.no" });
  assert.equal(proxy.connects.length, 4, "no_proxy must bypass the proxy");
  assert.equal(f.requests.length, before + 1);
});

test("identifies the plugin to MET, caps Expires at six hours and reports local times", async t => {
  const f = await fixture(t);
  f.responses.forecast.headers = { Expires: new Date(Date.now() + 24 * 3600 * 1000).toUTCString() };
  const report = await f.run();
  assert.equal(f.forecastHeaders[0]["user-agent"], "foamy-weather/1.4.0 (+https://github.com/foamrider/foamy-weather)");
  const [expires, lastModified] = (await fs.readFile(f.forecastPath.replace(/\.json$/, ".meta"), "utf8")).split("\n");
  const now = Math.floor(Date.now() / 1000);
  assert.ok(Number(expires) > now + 21500 && Number(expires) <= now + 21600, `Expires ${expires}`);
  assert.equal(lastModified, "");
  const mtime = Math.floor((await fs.stat(f.forecastPath)).mtimeMs / 1000);
  assert.equal(report.fetchedAt, (await exec("date", ["-Iseconds", "-d", `@${mtime}`])).stdout.trim());
  for (const [offset, day] of report.sun.entries())
    assert.equal(day.date, (await exec("date", ["-d", `+${offset} day`, "+%Y-%m-%d"])).stdout.trim());
  // A custom agent replaces the default; an Expires in the past is ignored.
  f.responses.forecast.headers = { Expires: new Date(Date.now() - 1000).toUTCString(), "Last-Modified": "Thu, 29 Oct 2026 10:00:00 GMT" };
  await f.run(true, { MET_WEATHER_USER_AGENT: "example-agent/1.0" });
  assert.equal(f.forecastHeaders[1]["user-agent"], "example-agent/1.0");
  assert.equal(await fs.readFile(f.forecastPath.replace(/\.json$/, ".meta"), "utf8"), "\nThu, 29 Oct 2026 10:00:00 GMT\n");
});

test("sun caches older than eight days are pruned after the reply", async t => {
  const f = await fixture(t);
  const day = 24 * 3600 * 1000;
  const old = path.join(f.cache, "sun-old-2000-01-01.json");
  const recent = path.join(f.cache, "sun-recent-2000-01-02.json");
  const other = path.join(f.cache, "location-old.json");
  for (const [file, age] of [[old, 8 * day + 60000], [recent, 7 * day], [other, 30 * day]]) {
    await fs.writeFile(file, sun);
    const time = new Date(Date.now() - age);
    await fs.utimes(file, time, time);
  }
  await f.run();
  const names = await fs.readdir(f.cache);
  assert.ok(!names.includes(path.basename(old)), "an old sun cache stayed");
  assert.ok(names.includes(path.basename(recent)), "a week-old sun cache was removed");
  assert.ok(names.includes(path.basename(other)), "only sun caches are pruned");
});
