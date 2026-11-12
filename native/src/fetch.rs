//! `fetch [--force]`: the MET forecast and sunrise bundle (weather-fetch.sh).

use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use serde_json::Value;

use crate::http::{self, Error, Request};
use crate::util::{self, Contents, keys};

const HOST: &str = "api.met.no";
const FORECAST_MAX_BYTES: usize = 2 * 1024 * 1024;
const SUN_MAX_BYTES: usize = 64 * 1024;
const EXPIRES_MAX_AGE: i64 = 21600;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const FORECAST_TIMEOUT: Duration = Duration::from_secs(10);
const SUN_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_INPUT: usize = 4096;

pub fn main(args: &[OsString]) -> ExitCode {
    foamy_helper::process::set_umask(0o077);
    util::print_line(&run(args));
    ExitCode::SUCCESS
}

/// Two `\n`-terminated lines from stdin, read without waiting for EOF
/// (the script's two `read -r`).
fn read_two_lines(input: &mut impl Read) -> Option<(String, String)> {
    let mut data = Vec::new();
    let mut byte = [0u8; 1];
    let mut lines = 0;
    while lines < 2 {
        if data.len() >= MAX_INPUT {
            return None;
        }
        match input.read(&mut byte) {
            Ok(0) => return None,
            Ok(_) => {
                data.push(byte[0]);
                if byte[0] == b'\n' {
                    lines += 1;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
    let text = String::from_utf8(data).ok()?;
    let mut lines = text.split('\n');
    Some((lines.next()?.to_string(), lines.next()?.to_string()))
}

/// The script's `valid_forecast` on content already bounded by size.
fn valid_forecast(data: &[u8]) -> bool {
    if data.is_empty() || data.len() > FORECAST_MAX_BYTES {
        return false;
    }
    let Some(doc) = util::parse_one(data) else {
        return false;
    };
    doc.get("type").and_then(Value::as_str) == Some("Feature")
        && doc
            .pointer("/properties/timeseries")
            .and_then(Value::as_array)
            .is_some_and(|series| !series.is_empty())
}

/// The script's `valid_sun`: the sunrise and sunset times, when valid.
fn sun_times(data: &[u8]) -> Option<(String, String)> {
    if data.is_empty() || data.len() > SUN_MAX_BYTES {
        return None;
    }
    let doc = util::parse_one(data)?;
    let time = |which: &str| {
        doc.pointer(&format!("/properties/{which}/time"))
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
            .map(str::to_string)
    };
    Some((time("sunrise")?, time("sunset")?))
}

/// Copies the first valid legacy cache to `target` with its times when
/// `target` is missing (the old file stays, as before).
fn migrate(target: &Path, legacy: &[PathBuf], limit: usize, valid: impl Fn(&[u8]) -> bool) {
    for old in legacy {
        if util::exists(target) {
            return;
        }
        let Some(Contents { data, atime, mtime }) = util::read_regular(old, limit as u64) else {
            continue;
        };
        if valid(&data) && util::write_private(target, &data).is_ok() {
            let _ = util::set_times(target, Some((atime, mtime)));
        }
    }
}

/// The Last-Modified the script would put in curl's config: an HTTP date
/// of the plain characters only.
fn plain_date(text: &str) -> Option<&str> {
    (!text.is_empty()
        && text.len() <= 64
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b" ,:+-".contains(&b)))
    .then_some(text)
}

/// The script's `save_meta`: MET's Expires (future, at most six hours
/// ahead) and Last-Modified (`fallback` when the reply has none).
fn save_meta(path: &Path, response: &http::Response, fallback: &str, now: i64) {
    let expires = response
        .header("expires")
        .and_then(util::http_date)
        .filter(|&e| e > now)
        .map(|e| e.min(now + EXPIRES_MAX_AGE).to_string())
        .unwrap_or_default();
    let last_modified = response
        .header("last-modified")
        .filter(|v| !v.is_empty())
        .unwrap_or(fallback);
    let last_modified = plain_date(last_modified).unwrap_or("");
    let _ = util::write_private(path, format!("{expires}\n{last_modified}\n").as_bytes());
}

enum Download {
    Fresh(http::Response),
    NotModified(http::Response),
    Failed(Error),
}

fn download_forecast(target: &str, user_agent: &str, last_modified: Option<&str>) -> Download {
    let request = Request {
        host: HOST,
        target,
        user_agent,
        if_modified_since: last_modified,
        connect_timeout: CONNECT_TIMEOUT,
        timeout: FORECAST_TIMEOUT,
        limit: FORECAST_MAX_BYTES,
    };
    match http::get(&request) {
        Ok(response) if response.status == 304 => Download::NotModified(response),
        Ok(response) if valid_forecast(&response.body) => Download::Fresh(response),
        Ok(_) => Download::Failed(Error::Failed("invalid forecast".into())),
        Err(error) => Download::Failed(error),
    }
}

fn run(args: &[OsString]) -> String {
    let force = match args {
        [] => false,
        [mode] if mode == "--force" => true,
        [mode] if mode.is_empty() => false,
        _ => return util::error_json(keys::CHOOSE_LOCATION, &[]),
    };
    let Some((latitude, longitude)) = read_two_lines(&mut std::io::stdin().lock()) else {
        return util::error_json(keys::CHOOSE_LOCATION, &[]);
    };
    let Some((latitude, longitude)) = util::coordinates(&latitude, &longitude) else {
        return util::error_json(keys::CHOOSE_LOCATION, &[]);
    };
    let user_agent = util::user_agent("MET_WEATHER_USER_AGENT");
    let cache_max_age = util::env_seconds("MET_WEATHER_CACHE_MAX_AGE", 1800);
    let force_min_age = util::env_seconds("MET_WEATHER_FORCE_MIN_AGE", 60);

    // MET asks for limited precision so shared caches stay useful; three
    // decimals (about 100 m) lose nothing for a forecast.
    let (lat3, lon3) = (util::fixed(latitude, 3), util::fixed(longitude, 3));
    let (lat4, lon4) = (util::fixed(latitude, 4), util::fixed(longitude, 4));
    // Opaque names keep coordinates out of file names.
    let key = util::sha256_hex(&format!("{lat3}_{lon3}"));
    // Versions up to 1.1 hashed the four-decimal coordinates.
    let legacy_key = util::sha256_hex(&format!("{lat4}_{lon4}"));

    let root = util::cache_root();
    if util::private_dir(&root, true).is_err() {
        return util::error_json(keys::UNAVAILABLE, &[]);
    }
    let forecast_cache = root.join(format!("forecast-complete-{key}.json"));
    let forecast_meta = root.join(format!("forecast-complete-{key}.meta"));
    migrate(
        &forecast_cache,
        &[
            root.join(format!("forecast-complete-{legacy_key}.json")),
            root.join(format!("forecast-complete-{lat4}_{lon4}.json")),
        ],
        FORECAST_MAX_BYTES,
        valid_forecast,
    );

    let now = util::now();
    let cache = util::read_regular(&forecast_cache, FORECAST_MAX_BYTES as u64)
        .filter(|c| valid_forecast(&c.data));
    let mut fresh = false;
    let mut cached_last_modified = String::new();
    if let Some(cache) = &cache {
        let age = now - cache.mtime.tv_sec;
        let meta = util::read_regular(&forecast_meta, 4096)
            .map(|m| String::from_utf8_lossy(&m.data).into_owned())
            .unwrap_or_default();
        let mut lines = meta.split('\n');
        let expires = lines
            .next()
            .filter(|e| !e.is_empty() && e.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|e| e.parse::<i64>().ok());
        cached_last_modified = plain_date(lines.next().unwrap_or(""))
            .unwrap_or("")
            .to_string();
        fresh = if force {
            age < force_min_age
        } else if let Some(expires) = expires {
            now < expires
        } else {
            age < cache_max_age
        };
    }

    let mut cached = cache.map(|c| c.data);
    let mut stale = false;
    if !fresh {
        let target = format!("/weatherapi/locationforecast/2.0/complete?lat={lat3}&lon={lon3}");
        let validator = (cached.is_some() && !cached_last_modified.is_empty())
            .then_some(cached_last_modified.as_str());
        match download_forecast(&target, &user_agent, validator) {
            Download::Fresh(response) => {
                if util::write_private(&forecast_cache, &response.body).is_ok() {
                    save_meta(&forecast_meta, &response, "", util::now());
                }
                cached = Some(response.body);
            }
            // Unchanged on MET's side: the cached forecast is current again.
            Download::NotModified(response) if cached.is_some() => {
                let _ = util::set_times(&forecast_cache, None);
                save_meta(
                    &forecast_meta,
                    &response,
                    &cached_last_modified,
                    util::now(),
                );
            }
            Download::NotModified(_) => return util::error_json(keys::UNAVAILABLE, &[]),
            Download::Failed(error) => {
                if cached.is_none() {
                    // A failed refresh must not replace useful conditions with an empty panel.
                    let key = if error == Error::Unsupported {
                        foamy_helper::tls::UNSUPPORTED
                    } else {
                        keys::UNAVAILABLE
                    };
                    return util::error_json(key, &[]);
                }
                stale = true;
            }
        }
    }
    let Some(forecast) = cached else {
        return util::error_json(keys::UNAVAILABLE, &[]);
    };

    // Sunrise times are extras and each request may take SUN_TIMEOUT. A
    // forecast refresh that just failed means MET or the network is down, and
    // after one failed sunrise request the next days' would fail the same
    // way; read the caches then, but send nothing more.
    let mut sun_requests = !stale;
    let mut sun = Vec::new();
    for offset in 0..3 {
        let date = util::local_date_after(offset, now);
        let sun_cache = root.join(format!("sun-{key}-{date}.json"));
        migrate(
            &sun_cache,
            &[
                root.join(format!("sun-{legacy_key}-{date}.json")),
                root.join(format!("sun-{lat4}_{lon4}-{date}.json")),
            ],
            SUN_MAX_BYTES,
            |data| sun_times(data).is_some(),
        );
        let mut times =
            util::read_regular(&sun_cache, SUN_MAX_BYTES as u64).and_then(|c| sun_times(&c.data));
        if times.is_none() && sun_requests {
            let target = format!("/weatherapi/sunrise/3.0/sun?lat={lat3}&lon={lon3}&date={date}");
            let request = Request {
                host: HOST,
                target: &target,
                user_agent: &user_agent,
                if_modified_since: None,
                connect_timeout: CONNECT_TIMEOUT,
                timeout: SUN_TIMEOUT,
                limit: SUN_MAX_BYTES,
            };
            if let Ok(response) = http::get(&request)
                && let Some(valid) = sun_times(&response.body)
            {
                let _ = util::write_private(&sun_cache, &response.body);
                times = Some(valid);
            } else {
                sun_requests = false;
            }
        }
        let (sunrise, sunset) = times.unwrap_or_default();
        sun.push(format!(
            "{{\"date\":{},\"sunrise\":{},\"sunset\":{}}}",
            util::json_string(&date),
            util::json_string(&sunrise),
            util::json_string(&sunset)
        ));
    }

    let Some(fetched) = util::mtime(&forecast_cache) else {
        return util::error_json(keys::UNAVAILABLE, &[]);
    };
    let forecast =
        String::from_utf8(util::minify(&forecast)).unwrap_or_else(|_| "null".to_string());
    let reply = format!(
        "{{\"forecast\":{forecast},\"sun\":[{}],\"fetchedAt\":{},\"stale\":{stale}}}",
        sun.join(","),
        util::json_string(&util::iso_seconds(fetched))
    );
    prune_sun(&root, util::now());
    reply
}

/// `find <root> -maxdepth 1 -type f -name 'sun-*.json' -mtime +7 -delete`:
/// sun data is immutable for its date; keep only a small rolling set.
fn prune_sun(root: &Path, now: i64) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !(name.starts_with("sun-") && name.ends_with(".json") && name.len() >= 9) {
            continue;
        }
        let path = entry.path();
        if let Some(mtime) = util::mtime(&path)
            && (now - mtime).div_euclid(86400) > 7
        {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stdin_needs_two_terminated_lines() {
        let read = |input: &[u8]| read_two_lines(&mut &input[..]);
        assert_eq!(read(b"12\n34\n"), Some(("12".into(), "34".into())));
        assert_eq!(
            read(b"12\n34\nrest ignored"),
            Some(("12".into(), "34".into()))
        );
        assert_eq!(read(b"12\n34"), None);
        assert_eq!(read(b"12.3456\n"), None);
        assert_eq!(read(b""), None);
        assert_eq!(read(&[b'1'; MAX_INPUT + 10]), None);
    }

    #[test]
    fn documents_must_have_the_scripts_shape() {
        assert!(valid_forecast(
            br#"{"type":"Feature","properties":{"timeseries":[{}]}}"#
        ));
        for bad in [
            &br#"{"type":"Feature","properties":{"timeseries":[]}}"#[..],
            br#"{"type":"Feature","properties":{"timeseries":"wrong"}}"#,
            br#"{"type":"Point","properties":{"timeseries":[1]}}"#,
            br#"[{"type":"Feature"}]"#,
            br#"{"type":"Feature","properties":{"timeseries":[1]}} {}"#,
            b"{broken",
            b"",
            b"   ",
        ] {
            assert!(!valid_forecast(bad), "{}", String::from_utf8_lossy(bad));
        }
        assert_eq!(
            sun_times(br#"{"properties":{"sunrise":{"time":"a"},"sunset":{"time":"b"}}}"#),
            Some(("a".into(), "b".into()))
        );
        assert_eq!(
            sun_times(br#"{"properties":{"sunrise":{"time":123},"sunset":{"time":true}}}"#),
            None
        );
        assert_eq!(
            sun_times(br#"{"properties":{"sunrise":{"time":""},"sunset":{"time":"b"}}}"#),
            None
        );
    }

    #[test]
    fn validators_are_plain_dates() {
        assert_eq!(
            plain_date("Thu, 29 Oct 2026 10:00:00 GMT"),
            Some("Thu, 29 Oct 2026 10:00:00 GMT")
        );
        assert_eq!(plain_date("Thu\r\nX: y"), None);
        assert_eq!(plain_date("\"quoted\""), None);
        assert_eq!(plain_date(""), None);
        assert_eq!(plain_date(&"a".repeat(65)), None);
    }
}
