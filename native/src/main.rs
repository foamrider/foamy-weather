//! `foamy-weather-helper`: forecasts from MET Norway, the searched place,
//! the automatic (GeoClue) position and the place search, for Foamy Weather.
//! Replaces `scripts/weather-fetch.sh`, `scripts/weather-location.sh` and
//! `scripts/weather-resolve-location.sh`, and the `curl` the place search ran.
//!
//! # Contract
//!
//! Coordinates and place names only ever travel through stdin, stdout and
//! files, never through argv (procfs shows argv to every user). No
//! subcommand exits 126 or 127 (reserved for "helper unavailable").
//!
//! ## `fetch [--force]` (was weather-fetch.sh)
//!
//! - **stdin**: two `\n`-terminated lines, latitude then longitude, each
//!   `-?[0-9]+(\.[0-9]+)?` within ±90 / ±180 (at most 4096 bytes are read;
//!   reading stops after the second line, EOF is not awaited). Anything else,
//!   or another argument, is `{"error":"Choose a location to load
//!   weather","values":[]}` before any request.
//! - **stdout**: one JSON line, always, exit 0: `{"forecast":<MET's
//!   document, whitespace removed>,"sun":[{"date":"YYYY-MM-DD","sunrise":"…",
//!   "sunset":"…"}×3],"fetchedAt":"<cache mtime, local ISO 8601 with
//!   ±HH:MM>","stale":<bool>}`, or `{"error":<English key>,"values":[…]}`
//!   (`Weather data is unavailable`; on a CPU without the instructions
//!   Graviola needs and no usable cache, `foamy_helper::tls::UNSUPPORTED`).
//!   Sunrise/sunset that could not be loaded are `""`.
//! - **Coordinates** are rounded to three decimals (`%.3f`, as awk did) for
//!   MET (`/weatherapi/locationforecast/2.0/complete?lat=&lon=`,
//!   `/weatherapi/sunrise/3.0/sun?lat=&lon=&date=` for today and the next two
//!   local dates).
//! - **Cache**: `${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-weather` (created
//!   0700 under umask 077, then `chmod 700`; must be this user's).
//!   `forecast-complete-<sha256 of "lat_lon">.json`, `.meta` (line 1:
//!   Expires as epoch seconds or empty, line 2: Last-Modified or empty),
//!   `sun-<key>-<date>.json`; all 0600, replaced atomically, never through a
//!   symlink. Caches of 1.1 (key of the four-decimal coordinates) and older
//!   (`forecast-complete-<lat4>_<lon4>.json`, `sun-<lat4>_<lon4>-<date>.json`)
//!   are copied to the new name with their times when it is missing (the old
//!   file stays). Sun caches older than 8 days (`find -mtime +7`) are removed
//!   after the reply.
//! - **Freshness**: a valid cache (0 < size ≤ limit, one JSON document of
//!   the right shape) is used without a request when: `--force` and younger
//!   than `MET_WEATHER_FORCE_MIN_AGE` s (default 60); else, when the meta has
//!   an Expires, before it; else younger than `MET_WEATHER_CACHE_MAX_AGE` s
//!   (default 1800). Expires is honoured only in the future and capped at six
//!   hours. A refresh of a valid cache sends `If-Modified-Since` with the
//!   stored Last-Modified; 304 renews the cache's mtime and keeps the stored
//!   Last-Modified when the reply has none. A failed refresh with a valid
//!   cache reports it with `"stale":true`. A sun cache is valid for its date
//!   forever.
//! - **Limits**: decoded bodies of 2 MiB (forecast) and 64 KiB (sun); one
//!   byte more is a failure. Forecast: 3 s to connect (DNS, TCP, proxy, TLS),
//!   10 s in all; sun: 3 s / 8 s.
//! - **Env**: `MET_WEATHER_USER_AGENT` (non-empty, printable ASCII; else the
//!   default below), `MET_WEATHER_CACHE_MAX_AGE`, `MET_WEATHER_FORCE_MIN_AGE`.
//!
//! ## `location --set | --clear | --migrate` (was weather-location.sh)
//!
//! The searched place, `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/
//! settings/foamy-weather-location.json` (directories made with the normal
//! umask: it is Omarchy's settings directory), one line
//! `{"name":…,"latitude":…,"longitude":…}`, 0600. The legacy file is
//! `${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/weather-location.local.json`.
//! A valid location is one JSON object (at most 64 KiB) with a non-empty
//! string `name`, `latitude` in ±90 and `longitude` in ±180 (numbers).
//!
//! - `--set`: the location from stdin replaces the file atomically. Invalid:
//!   `Invalid location` on stderr, exit 2.
//! - `--clear` (any further arguments ignored): removes both files; exit 0,
//!   1 when one could not be removed.
//! - `--migrate`: no legacy file: exit 0. A valid state file wins (the
//!   legacy file is removed); an invalid one, or an invalid legacy file, is
//!   left alone (exit 0). Else the legacy location is linked into place
//!   without replacing a file that appeared meanwhile (a concurrent `--set`
//!   wins; exit 0), read back (exit 1 if it differs), and the legacy file is
//!   removed.
//! - Anything else: usage on stderr, exit 2.
//!
//! ## `resolve-location [--force]` (was weather-resolve-location.sh)
//!
//! - **stdout**: one JSON line, exit 0: `{"name":…,"latitude":<%.2f>,
//!   "longitude":<%.2f>,"source":"geoclue"|"geoclue-cache"}` or
//!   `{"error":…,"values":[…]}`: `Unknown option: %1` (only the first
//!   argument is checked), `Automatic location needs XDG_RUNTIME_DIR`,
//!   `Automatic location storage is not private`, `Could not find automatic
//!   location`.
//! - **Position** (runtime data, never `/tmp`):
//!   `$WEATHER_LOCATION_RUNTIME_DIR`, else
//!   `$XDG_RUNTIME_DIR/omarchy-weather-$UID`; created 0700, refused when it is
//!   a symlink or not this user's, then `chmod 700`. `current-location.json`
//!   (0600) is reused for `WEATHER_LOCATION_CACHE_MAX_AGE` s (default 900)
//!   unless `--force`, which deletes it first.
//! - **GeoClue**: `$WEATHER_GEOCLUE_COMMAND` (default
//!   `/usr/lib/geoclue-2.0/demos/where-am-i`), no arguments, if executable,
//!   for at most 5 s (then its process group is killed) and 64 KiB of output;
//!   the first `Latitude:`/`Longitude:` lines' second field, `,` read as `.`,
//!   rounded to two decimals (about 1 km) before anything else sees them.
//! - **Place name**: `${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-weather/
//!   location-<sha256 of "lat_lon">.json` (`{"name":…}`, 0600, legacy
//!   `location-<lat>_<lon>.json` copied with its time) for
//!   `WEATHER_LOCATION_LABEL_CACHE_MAX_AGE` s (default 604800), else
//!   Nominatim `/reverse?format=jsonv2&lat=&lon=&zoom=10&addressdetails=1`
//!   (3 s / 8 s, 256 KiB): the first of address city, town, village,
//!   municipality, county, else `"<lat>, <lon>"`; cached either way.
//! - **Env**: `WEATHER_LOCATION_USER_AGENT` as `MET_WEATHER_USER_AGENT`.
//!
//! ## `geocode` (was Panel.qml's `curl -fsS --max-time 5 --config -`)
//!
//! - **stdin**: `{"query":<text, 1–512 bytes>,"language":<two lowercase
//!   letters, else "en">}` (at most 16 KiB).
//! - **stdout**, exit 0: Open-Meteo's reply to
//!   `/v1/search?name=<encodeURIComponent(query)>&count=5&language=&format=json`
//!   as received (5 s in all, 256 KiB), or `{"error":"Could not search for a
//!   location"}` / `{"error":<tls::UNSUPPORTED>}`.
//!
//! ## HTTP (all requests)
//!
//! HTTPS GET over HTTP/1.1 (`Connection: close`) to `api.met.no`,
//! `nominatim.openstreetmap.org` or `geocoding-api.open-meteo.com`, rustls
//! with Graviola and the system trust store (`SSL_CERT_FILE`/`SSL_CERT_DIR`
//! honoured), every socket under `foamy_helper::net::DeadlineStream` with
//! the request's absolute deadline. `User-Agent: foamy-weather/1.3.0
//! (+https://github.com/foamrider/foamy-weather)` unless overridden (MET's
//! terms require an identifying agent), `Accept: */*`, `Accept-Encoding:
//! gzip, deflate`. Status 400 and above is a failure (curl `--fail`); no
//! redirects. Proxies as curl: `https_proxy`/`HTTPS_PROXY`, else
//! `all_proxy`/`ALL_PROXY` (`http://[user:pass@]host[:port]`, port 1080 by
//! default, CONNECT; any other scheme fails the request), skipped for hosts
//! in `no_proxy`/`NO_PROXY` (`*`, or names matching themselves and their
//! subdomains). The host's (or proxy's) addresses are tried as curl does,
//! Happy Eyeballs: families alternating, each attempt on its own thread,
//! the next one 200 ms later or as soon as the previous fails, the first
//! connection winning within the connect timeout. A 204 or 304 has no body
//! (its Content-Encoding is not applied), and an empty body is empty
//! whatever its Content-Encoding (curl `--compressed`).
//!
//! **Test-only override**: `FOAMY_WEATHER_TEST_CONNECT=<loopback ip>:<port>[,…]`
//! stands in for the resolved addresses of every direct connection (TLS is
//! still verified for the real host name, so tests point `SSL_CERT_FILE` at
//! their own CA); a non-loopback address fails the request.

use std::ffi::{OsStr, OsString};
use std::process::ExitCode;

mod fetch;
mod geocode;
mod http;
mod location;
mod resolve;
mod util;

fn main() -> ExitCode {
    foamy_helper::process::exit_on_panic(101);
    let mut args = std::env::args_os().skip(1);
    let command = args.next();
    let rest: Vec<OsString> = args.collect();
    match command.as_deref().and_then(OsStr::to_str) {
        Some("fetch") => fetch::main(&rest),
        Some("location") => location::main(&rest),
        Some("resolve-location") => resolve::main(&rest),
        Some("geocode") => geocode::main(&rest),
        _ => {
            eprintln!(
                "Usage: foamy-weather-helper fetch [--force] | location --set|--clear|--migrate | resolve-location [--force] | geocode"
            );
            ExitCode::from(2)
        }
    }
}
