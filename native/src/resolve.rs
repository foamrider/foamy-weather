//! `resolve-location [--force]`: the automatic position from GeoClue and a
//! place name for it (weather-resolve-location.sh).

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use rustix::fs::Access;
use rustix::process::getuid;
use serde_json::Value;

use crate::http::{self, Request};
use crate::util::{self, keys};

const DEFAULT_GEOCLUE: &str = "/usr/lib/geoclue-2.0/demos/where-am-i";
const GEOCLUE_TIMEOUT: Duration = Duration::from_secs(5);
const GEOCLUE_MAX_OUTPUT: usize = 64 * 1024;
const NOMINATIM: &str = "nominatim.openstreetmap.org";
const LABEL_MAX_BYTES: usize = 256 * 1024;
const MAX_CACHE_FILE: u64 = 64 * 1024;

pub fn main(args: &[OsString]) -> ExitCode {
    foamy_helper::process::set_umask(0o077);
    util::print_line(&run(args));
    ExitCode::SUCCESS
}

/// `{"name":…,"latitude":…,"longitude":…,"source":…}`; the coordinates
/// are the `%.2f` text, as `tonumber` kept it.
fn emit(name: &str, latitude: &str, longitude: &str, source: &str) -> String {
    format!(
        "{{\"name\":{},\"latitude\":{latitude},\"longitude\":{longitude},\"source\":{}}}",
        util::json_string(name),
        util::json_string(source)
    )
}

/// `{"name": …}` as `jq -Rs '{name: .}'` printed it (indented, newline).
fn label_file(label: &str) -> String {
    format!("{{\n  \"name\": {}\n}}\n", util::json_string(label))
}

fn field<'a>(doc: &'a Value, key: &str) -> Option<&'a Value> {
    doc.get(key)
}

/// The script's `cached_geoclue_location`.
fn cached_location(path: &Path, max_age: i64) -> Option<String> {
    let cache = util::read_regular(path, MAX_CACHE_FILE)?;
    if util::now() - cache.mtime.tv_sec >= max_age {
        return None;
    }
    let doc = util::parse_one(&cache.data)?;
    let name = util::jq_raw(field(&doc, "name")).unwrap_or_default();
    let latitude = util::jq_raw(field(&doc, "latitude"))?;
    let longitude = util::jq_raw(field(&doc, "longitude"))?;
    let (latitude, longitude) = util::coordinates(&latitude, &longitude)?;
    // Caches written by older versions kept four decimals.
    Some(emit(
        &name,
        &util::fixed(latitude, 2),
        &util::fixed(longitude, 2),
        "geoclue-cache",
    ))
}

/// The label in a `{"name": …}` file, if any.
fn read_label(path: &Path) -> Option<String> {
    let cache = util::read_regular(path, MAX_CACHE_FILE)?;
    let doc = util::parse_one(&cache.data)?;
    util::jq_raw(doc.get("name")).filter(|l| !l.is_empty())
}

/// Nominatim's place: the first of city, town, village, municipality and
/// county (`jq '… // …'`), or `None`.
fn nominatim_label(body: &[u8]) -> Option<String> {
    let doc = util::parse_one(body)?;
    let address = doc.get("address");
    ["city", "town", "village", "municipality", "county"]
        .iter()
        .find_map(|key| util::jq_raw(address.and_then(|a| a.get(key))))
        .filter(|l| !l.is_empty())
}

/// The script's `location_label` for rounded coordinates.
fn location_label(latitude: &str, longitude: &str, cache_root: &Path, user_agent: &str) -> String {
    let key = util::sha256_hex(&format!("{latitude}_{longitude}"));
    let cache_file = cache_root.join(format!("location-{key}.json"));
    // Legacy paths can disclose the rounded location even under a private directory.
    let legacy = cache_root.join(format!("location-{latitude}_{longitude}.json"));
    if !util::exists(&cache_file)
        && let Some(contents) = util::read_regular(&legacy, MAX_CACHE_FILE)
        && let Some(label) = util::parse_one(&contents.data)
            .and_then(|doc| util::jq_raw(doc.get("name")))
            .filter(|l| !l.is_empty())
        && util::write_private(&cache_file, label_file(&label).as_bytes()).is_ok()
    {
        let _ = util::set_times(&cache_file, Some((contents.atime, contents.mtime)));
    }

    let max_age = util::env_seconds("WEATHER_LOCATION_LABEL_CACHE_MAX_AGE", 604800);
    if let Some(mtime) = util::mtime(&cache_file)
        && util::now() - mtime < max_age
        && let Some(label) = read_label(&cache_file)
    {
        return label;
    }

    // A city name needs no more than about 1 km of precision.
    let target =
        format!("/reverse?format=jsonv2&lat={latitude}&lon={longitude}&zoom=10&addressdetails=1");
    let request = Request {
        host: NOMINATIM,
        target: &target,
        user_agent,
        if_modified_since: None,
        connect_timeout: Duration::from_secs(3),
        timeout: Duration::from_secs(8),
        limit: LABEL_MAX_BYTES,
    };
    let label = http::get(&request)
        .ok()
        .and_then(|response| nominatim_label(&response.body))
        .unwrap_or_else(|| format!("{latitude}, {longitude}"));
    let _ = util::write_private(&cache_file, label_file(&label).as_bytes());
    label
}

/// awk's `/Latitude:/ {gsub(/,/, ".", $2); gsub(/[^0-9.+-]/, "", $2); print $2; exit}`.
fn geoclue_value(output: &str, label: &str) -> Option<String> {
    let line = output.lines().find(|line| line.contains(label))?;
    let second = line
        .split([' ', '\t'])
        .filter(|f| !f.is_empty())
        .nth(1)
        .unwrap_or("");
    Some(
        second
            .replace(',', ".")
            .chars()
            .filter(|c| c.is_ascii_digit() || matches!(c, '.' | '+' | '-'))
            .collect(),
    )
}

fn geoclue_command() -> PathBuf {
    util::env_path("WEATHER_GEOCLUE_COMMAND").unwrap_or_else(|| PathBuf::from(DEFAULT_GEOCLUE))
}

/// The script's `geoclue_location`.
fn geoclue_location(
    force: bool,
    location_cache: &Path,
    cache_root: &Path,
    user_agent: &str,
) -> Option<String> {
    if !force
        && let Some(cached) = cached_location(
            location_cache,
            util::env_seconds("WEATHER_LOCATION_CACHE_MAX_AGE", 900),
        )
    {
        return Some(cached);
    }
    let command = geoclue_command();
    rustix::fs::access(&command, Access::EXEC_OK).ok()?;
    let output = foamy_helper::child::Bounded::new(&command)
        .timeout(GEOCLUE_TIMEOUT)
        .max_output(GEOCLUE_MAX_OUTPUT)
        .run()
        .map(|output| output.stdout_lossy())
        .unwrap_or_default();
    let latitude = geoclue_value(&output, "Latitude:")?;
    let longitude = geoclue_value(&output, "Longitude:")?;
    let (latitude, longitude) = util::coordinates(&latitude, &longitude)?;
    // Round to two decimals (about 1 km): enough for a forecast and a place
    // name, less precise than a home address, and steady across Wi-Fi jitter.
    let (latitude, longitude) = (util::fixed(latitude, 2), util::fixed(longitude, 2));
    let name = location_label(&latitude, &longitude, cache_root, user_agent);
    let line = emit(&name, &latitude, &longitude, "geoclue");
    let _ = util::write_private(location_cache, format!("{line}\n").as_bytes());
    Some(line)
}

fn run(args: &[OsString]) -> String {
    // Only the first argument is an option, as before.
    let mode = args
        .first()
        .map(|a| a.to_string_lossy().into_owned())
        .unwrap_or_default();
    if !mode.is_empty() && mode != "--force" {
        return util::error_json(keys::UNKNOWN_OPTION, &[&mode]);
    }
    let force = mode == "--force";
    let user_agent = util::user_agent("WEATHER_LOCATION_USER_AGENT");
    // The current position is runtime data: keep it in the user's private
    // runtime directory, never in a shared /tmp fallback someone else could
    // pre-create.
    let runtime_root = match util::env_path("WEATHER_LOCATION_RUNTIME_DIR") {
        Some(dir) => dir,
        None => match util::env_path("XDG_RUNTIME_DIR") {
            Some(dir) => dir.join(format!("omarchy-weather-{}", getuid().as_raw())),
            None => return util::error_json(keys::NO_RUNTIME_DIR, &[]),
        },
    };
    let cache_root = util::cache_root();
    // Refuse a directory someone else owns (or a symlink) instead of
    // trusting or chmod-ing it.
    if util::private_dir(&runtime_root, false).is_err()
        || util::private_dir(&cache_root, true).is_err()
    {
        return util::error_json(keys::NOT_PRIVATE, &[]);
    }
    let location_cache = runtime_root.join("current-location.json");
    if force {
        let _ = util::remove(&location_cache);
    }
    geoclue_location(force, &location_cache, &cache_root, &user_agent)
        .unwrap_or_else(|| util::error_json(keys::NOT_FOUND, &[]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geoclue_output_is_read_like_awk() {
        let output = "Client object: /org/freedesktop/GeoClue2/Client/1\n\nNew location:\n\
                      Latitude:    59,913900°\nLongitude:   10.752200°\nAccuracy:    25.0 meters\n";
        assert_eq!(
            geoclue_value(output, "Latitude:").as_deref(),
            Some("59.913900")
        );
        assert_eq!(
            geoclue_value(output, "Longitude:").as_deref(),
            Some("10.752200")
        );
        assert_eq!(
            geoclue_value("Latitude:\n", "Latitude:").as_deref(),
            Some("")
        );
        assert_eq!(geoclue_value("nothing", "Latitude:"), None);
        assert_eq!(
            geoclue_value("x Latitude: -12.5° Latitude: 1\nLatitude: 9", "Latitude:").as_deref(),
            Some("")
        );
    }

    #[test]
    fn nominatim_labels_follow_the_jq_alternatives() {
        assert_eq!(
            nominatim_label(br#"{"address":{"town":"Example Town"}}"#).as_deref(),
            Some("Example Town")
        );
        assert_eq!(
            nominatim_label(br#"{"address":{"city":null,"village":"V","county":"C"}}"#).as_deref(),
            Some("V")
        );
        assert_eq!(nominatim_label(br#"{"address":{"city":""}}"#), None);
        assert_eq!(nominatim_label(b"{}"), None);
        assert_eq!(nominatim_label(b"[1]"), None);
        assert_eq!(nominatim_label(b"{broken"), None);
    }

    #[test]
    fn output_lines() {
        assert_eq!(
            emit("Oslo", "59.91", "-0.00", "geoclue"),
            r#"{"name":"Oslo","latitude":59.91,"longitude":-0.00,"source":"geoclue"}"#
        );
        assert_eq!(label_file("A\"b"), "{\n  \"name\": \"A\\\"b\"\n}\n");
    }
}
