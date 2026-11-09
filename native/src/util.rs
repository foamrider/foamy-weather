//! Pieces the subcommands share: coordinates, JSON output, cache names,
//! files with times, the cache directory and local time.

use std::fs::File;
use std::io::{self, ErrorKind, Read};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rustix::fs::{self as rfs, AtFlags, CWD, FileType, Mode, OFlags, Timespec, Timestamps};
use rustix::process::geteuid;
use serde_json::Value;
use sha2::{Digest, Sha256};

/// The error keys the helper prints: English text that is also the key of
/// the plugin's i18n catalogs (tests/i18n.test.cjs checks every one, and
/// `foamy_helper::tls::UNSUPPORTED`, has an entry).
pub mod keys {
    pub const CHOOSE_LOCATION: &str = "Choose a location to load weather";
    pub const UNAVAILABLE: &str = "Weather data is unavailable";
    pub const UNKNOWN_OPTION: &str = "Unknown option: %1";
    pub const NO_RUNTIME_DIR: &str = "Automatic location needs XDG_RUNTIME_DIR";
    pub const NOT_PRIVATE: &str = "Automatic location storage is not private";
    pub const NOT_FOUND: &str = "Could not find automatic location";
    pub const SEARCH_FAILED: &str = "Could not search for a location";
}

/// MET's terms ask for an agent that identifies the application.
pub const DEFAULT_USER_AGENT: &str =
    "foamy-weather/1.4.0 (+https://github.com/foamrider/foamy-weather)";

/// `{"error":key,"values":[…]}`, the scripts' `json_error`.
pub fn error_json(key: &str, values: &[&str]) -> String {
    serde_json::json!({ "error": key, "values": values }).to_string()
}

/// A JSON string literal.
pub fn json_string(text: &str) -> String {
    Value::from(text).to_string()
}

/// Prints one line on stdout; a closed stdout is not an error worth more.
pub fn print_line(line: &str) {
    use std::io::Write;
    let mut out = io::stdout().lock();
    let _ = out.write_all(line.as_bytes());
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

/// The scripts' `valid_coordinates`: `-?[0-9]+(\.[0-9]+)?` each, latitude
/// within ±90 and longitude within ±180.
pub fn coordinates(latitude: &str, longitude: &str) -> Option<(f64, f64)> {
    fn number(text: &str) -> Option<f64> {
        let digits = text.strip_prefix('-').unwrap_or(text);
        let (whole, fraction) = match digits.split_once('.') {
            Some((whole, fraction)) => (whole, Some(fraction)),
            None => (digits, None),
        };
        let decimal = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
        if !decimal(whole) || fraction.is_some_and(|f| !decimal(f)) {
            return None;
        }
        text.parse().ok()
    }
    let (lat, lon) = (number(latitude)?, number(longitude)?);
    ((-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)).then_some((lat, lon))
}

/// awk's `printf "%.<digits>f"` (both round half to even on the binary value).
pub fn fixed(value: f64, digits: usize) -> String {
    format!("{value:.digits$}")
}

/// `printf '%s' text | sha256sum`, the hex digest.
pub fn sha256_hex(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Seconds since the epoch.
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `${NAME:-default}` for a duration in seconds (an unparsable value is the
/// default).
pub fn env_seconds(name: &str, default: i64) -> i64 {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

/// `${NAME:-default}` for a path-valued variable.
pub fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

fn home() -> PathBuf {
    env_path("HOME").unwrap_or_else(|| PathBuf::from("/"))
}

/// `${XDG_<kind>_HOME:-$HOME/<fallback>}`.
pub fn xdg(kind: &str, fallback: &str) -> PathBuf {
    env_path(&format!("XDG_{kind}_HOME")).unwrap_or_else(|| home().join(fallback))
}

/// `${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-weather`.
pub fn cache_root() -> PathBuf {
    xdg("CACHE", ".cache").join("omarchy-weather")
}

/// A user agent from `name` (non-empty, printable ASCII, so it cannot
/// break the request head), else the default.
pub fn user_agent(name: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty() && v.bytes().all(|b| (0x20..0x7f).contains(&b)))
        .unwrap_or_else(|| DEFAULT_USER_AGENT.to_string())
}

/// `mkdir -p dir && chmod 700 dir` (under umask 077), refusing a directory
/// that isn't this user's instead of failing half-way like chmod did.
/// `follow`: the last component may be a symlink to a directory (the
/// scripts' `chmod` followed it); else a symlink is refused.
pub fn private_dir(dir: &Path, follow: bool) -> io::Result<()> {
    match std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
    {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let mut flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC;
    if !follow {
        flags |= OFlags::NOFOLLOW;
    }
    let fd = rfs::open(dir, flags, Mode::empty())?;
    let stat = rfs::fstat(&fd)?;
    if stat.st_uid != geteuid().as_raw() {
        return Err(io::Error::new(
            ErrorKind::PermissionDenied,
            "not owned by this user",
        ));
    }
    rfs::fchmod(&fd, Mode::from_raw_mode(0o700))?;
    Ok(())
}

/// A regular file's content and times.
pub struct Contents {
    pub data: Vec<u8>,
    pub atime: Timespec,
    pub mtime: Timespec,
}

/// Reads a regular file of at most `limit` bytes without following a
/// symlink or opening a FIFO or device. `None` when it is missing, not a
/// regular file, unreadable or larger than `limit`.
pub fn read_regular(path: &Path, limit: u64) -> Option<Contents> {
    let flags =
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY;
    let fd = rfs::open(path, flags, Mode::empty()).ok()?;
    let stat = rfs::fstat(&fd).ok()?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return None;
    }
    let mut data = Vec::new();
    File::from(fd).take(limit + 1).read_to_end(&mut data).ok()?;
    if data.len() as u64 > limit {
        return None;
    }
    Some(Contents {
        data,
        atime: Timespec {
            tv_sec: stat.st_atime as _,
            tv_nsec: stat.st_atime_nsec as _,
        },
        mtime: Timespec {
            tv_sec: stat.st_mtime as _,
            tv_nsec: stat.st_mtime_nsec as _,
        },
    })
}

/// A regular file (not a symlink): its mtime in seconds.
pub fn mtime(path: &Path) -> Option<i64> {
    let stat = rfs::statat(CWD, path, AtFlags::SYMLINK_NOFOLLOW).ok()?;
    (FileType::from_raw_mode(stat.st_mode) == FileType::RegularFile).then_some(stat.st_mtime as i64)
}

/// `test -e` (a dangling symlink does not exist).
pub fn exists(path: &Path) -> bool {
    path.exists()
}

/// `touch --reference=<file with these times>` on `path` (not following a
/// symlink); `None` times are now.
pub fn set_times(path: &Path, times: Option<(Timespec, Timespec)>) -> io::Result<()> {
    let now = Timespec {
        tv_sec: 0,
        tv_nsec: rfs::UTIME_NOW,
    };
    let (atime, mtime) = times.unwrap_or((now, now));
    let times = Timestamps {
        last_access: atime,
        last_modification: mtime,
    };
    rfs::utimensat(CWD, path, &times, AtFlags::SYMLINK_NOFOLLOW).map_err(io::Error::from)
}

/// Replaces `path` with `data` (0600) atomically through the kit.
pub fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
    foamy_helper::fs::write_atomic(path, data, 0o600)
}

/// `rm -f path`: `Ok` when it is gone (or never existed).
pub fn remove(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// `jq -r '<path> // empty'` for one value: `None` for a missing, `null`
/// or `false` value; strings raw, anything else as compact JSON. Like
/// `$(…)`, trailing newlines are dropped.
pub fn jq_raw(value: Option<&Value>) -> Option<String> {
    let text = match value? {
        Value::Null | Value::Bool(false) => return None,
        Value::String(text) => text.clone(),
        other => other.to_string(),
    };
    Some(text.trim_end_matches('\n').to_string())
}

/// One JSON document (jq `-s` with `length == 1`), or `None`.
pub fn parse_one(data: &[u8]) -> Option<Value> {
    serde_json::from_slice(data).ok()
}

/// JSON with the insignificant whitespace removed (`jq -c` without
/// re-encoding: number literals, escapes and key order stay as sent).
/// `data` must be valid JSON.
pub fn minify(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let (mut in_string, mut escaped) = (false, false);
    for &byte in data {
        if in_string {
            out.push(byte);
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
        } else if !matches!(byte, b' ' | b'\t' | b'\n' | b'\r') {
            if byte == b'"' {
                in_string = true;
            }
            out.push(byte);
        }
    }
    out
}

/// A local wall-clock time: the date and the UTC offset.
pub struct Local {
    pub year: i64,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub offset: i64,
}

/// `localtime_r` (TZ or /etc/localtime, as `date`; musl and glibc load the
/// zone themselves); UTC when it fails.
pub fn local(time: i64) -> Local {
    let mut tm = std::mem::MaybeUninit::<libc::tm>::zeroed();
    // time_t is 64 bits on both targets (x86_64, aarch64; musl >= 1.2).
    let t: i64 = time;
    // SAFETY: `t` (a 64-bit time_t) and `tm` are valid for the call;
    // localtime_r reads `t` and writes only `tm`.
    let ok =
        !unsafe { libc::localtime_r(std::ptr::from_ref(&t).cast(), tm.as_mut_ptr()) }.is_null();
    if !ok {
        let (year, month, day) = civil_from_days(time.div_euclid(86400));
        let rest = time.rem_euclid(86400);
        return Local {
            year,
            month,
            day,
            hour: (rest / 3600) as u32,
            minute: (rest / 60 % 60) as u32,
            second: (rest % 60) as u32,
            offset: 0,
        };
    }
    // SAFETY: localtime_r succeeded and initialised `tm`.
    let tm = unsafe { tm.assume_init() };
    Local {
        year: tm.tm_year as i64 + 1900,
        month: (tm.tm_mon + 1) as u32,
        day: tm.tm_mday as u32,
        hour: tm.tm_hour as u32,
        minute: tm.tm_min as u32,
        second: tm.tm_sec as u32,
        offset: tm.tm_gmtoff,
    }
}

/// `date -d "+<days> day" +%Y-%m-%d`: the local date `days` after today.
pub fn local_date_after(days: i64, now: i64) -> String {
    let today = local(now);
    let (year, month, day) =
        civil_from_days(days_from_civil(today.year, today.month, today.day) + days);
    format!("{year:04}-{month:02}-{day:02}")
}

/// `date -Iseconds -d @time`: `YYYY-MM-DDTHH:MM:SS±HH:MM`.
pub fn iso_seconds(time: i64) -> String {
    let t = local(time);
    let sign = if t.offset < 0 { '-' } else { '+' };
    let offset = t.offset.abs();
    let mut text = format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{sign}{:02}:{:02}",
        t.year,
        t.month,
        t.day,
        t.hour,
        t.minute,
        t.second,
        offset / 3600,
        offset / 60 % 60
    );
    if offset % 60 != 0 {
        text.push_str(&format!(":{:02}", offset % 60));
    }
    text
}

/// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant).
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let month = month as i64;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// The date of a day count since 1970-01-01.
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

/// An HTTP date (`date -d` for what servers send): IMF-fixdate
/// `Sun, 06 Nov 1994 08:49:37 GMT`, RFC 850 `Sunday, 06-Nov-94 08:49:37
/// GMT` and asctime `Sun Nov  6 08:49:37 1994`, as epoch seconds.
pub fn http_date(text: &str) -> Option<i64> {
    const MONTHS: [&str; 12] = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    let month_of = |name: &str| {
        MONTHS
            .iter()
            .position(|m| name.eq_ignore_ascii_case(m))
            .map(|i| i as u32 + 1)
    };
    let number = |part: &str| -> Option<i64> {
        (!part.is_empty() && part.len() <= 4 && part.bytes().all(|b| b.is_ascii_digit()))
            .then(|| part.parse().ok())
            .flatten()
    };
    let clock = |part: &str| -> Option<i64> {
        let mut fields = part.split(':');
        let (h, m, s) = (
            number(fields.next()?)?,
            number(fields.next()?)?,
            number(fields.next()?)?,
        );
        (fields.next().is_none() && h < 24 && m < 60 && s <= 60).then_some(h * 3600 + m * 60 + s)
    };
    let utc = |zone: &str| {
        matches!(
            zone.to_ascii_uppercase().as_str(),
            "GMT" | "UTC" | "UT" | "Z" | "+0000" | "-0000"
        )
    };
    let words: Vec<&str> = text.split_ascii_whitespace().collect();
    let (year, month, day, seconds) = match words.as_slice() {
        // IMF-fixdate.
        [weekday, day, month, year, time, zone] if weekday.ends_with(',') && utc(zone) => {
            (number(year)?, month_of(month)?, number(day)?, clock(time)?)
        }
        // RFC 850.
        [weekday, date, time, zone] if weekday.ends_with(',') && utc(zone) => {
            let mut parts = date.split('-');
            let (day, month, year) = (parts.next()?, parts.next()?, parts.next()?);
            if parts.next().is_some() {
                return None;
            }
            let mut year = number(year)?;
            if year < 100 {
                year += if year < 69 { 2000 } else { 1900 };
            }
            (year, month_of(month)?, number(day)?, clock(time)?)
        }
        // asctime.
        [_, month, day, time, year] => {
            (number(year)?, month_of(month)?, number(day)?, clock(time)?)
        }
        _ => return None,
    };
    if !(1..=31).contains(&day) || year < 1970 {
        return None;
    }
    Some(days_from_civil(year, month, day as u32) * 86400 + seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coordinates_follow_the_scripts_pattern_and_ranges() {
        assert_eq!(coordinates("12", "-34.5"), Some((12.0, -34.5)));
        assert_eq!(coordinates("-90", "180"), Some((-90.0, 180.0)));
        assert_eq!(coordinates("-0", "000.000"), Some((-0.0, 0.0)));
        for (lat, lon) in [
            ("90.0001", "0"),
            ("0", "-180.5"),
            ("+1", "2"),
            ("1.", "2"),
            (".5", "2"),
            ("1e2", "2"),
            ("12;echo", "34"),
            ("", "1"),
            (" 1", "2"),
            ("1\r", "2"),
            ("0x10", "2"),
            ("inf", "2"),
            ("NaN", "2"),
        ] {
            assert_eq!(coordinates(lat, lon), None, "{lat:?} {lon:?}");
        }
    }

    #[test]
    fn rounding_matches_awk_printf() {
        // `awk 'BEGIN { printf "%.3f %.2f", … }'` on glibc.
        for (value, three, two) in [
            (0.0625, "0.062", "0.06"),
            (-0.0001, "-0.000", "-0.00"),
            (0.125, "0.125", "0.12"),
            (2.675, "2.675", "2.67"),
            (1.0005, "1.000", "1.00"),
            (12.3456, "12.346", "12.35"),
            (-56.789, "-56.789", "-56.79"),
            (-0.0, "-0.000", "-0.00"),
        ] {
            assert_eq!(fixed(value, 3), three);
            assert_eq!(fixed(value, 2), two);
        }
    }

    #[test]
    fn cache_keys_are_sha256sum_of_the_rounded_pair() {
        // printf '%s' 12.000_34.000 | sha256sum
        assert_eq!(
            sha256_hex("12.000_34.000"),
            "9258797968af04bc02bceb63453da7f2af6634844f062430d1e1ee608459545a"
        );
        assert_eq!(
            sha256_hex("12.35_-56.79"),
            "0eda377447654d618f7e83679e8266f32f3e708e31967338bbf9383aebbfb11a"
        );
        assert_eq!(
            sha256_hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn http_dates_cover_the_three_formats() {
        let expected = 784111777; // 1994-11-06T08:49:37Z
        assert_eq!(http_date("Sun, 06 Nov 1994 08:49:37 GMT"), Some(expected));
        assert_eq!(http_date("Sunday, 06-Nov-94 08:49:37 GMT"), Some(expected));
        assert_eq!(http_date("Sun Nov  6 08:49:37 1994"), Some(expected));
        assert_eq!(http_date("Thu, 29 Oct 2026 10:00:00 UTC"), Some(1793268000));
        for bad in [
            "",
            "0",
            "-1",
            "Sun, 06 Nov 1994 08:49:37 CET",
            "Sun, 32 Nov 1994 08:49:37 GMT",
            "Sun, 06 Foo 1994 08:49:37 GMT",
            "Sun, 06 Nov 1994 25:00:00 GMT",
            "Sun, 06 Nov 1994 08:49 GMT",
        ] {
            assert_eq!(http_date(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn civil_dates_round_trip() {
        for days in [-1, 0, 59, 365, 10957, 20759, 2932896] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20763), (2026, 11, 6));
        assert_eq!(
            days_from_civil(2024, 2, 29) + 1,
            days_from_civil(2024, 3, 1)
        );
    }

    #[test]
    fn minify_keeps_strings_and_literals() {
        let text = b"{ \"a\" : [1.50, 1E+2 ,\n\t\"x \\\" y\"],\r\n \"b\":\"\\\\\" }";
        assert_eq!(
            minify(text),
            b"{\"a\":[1.50,1E+2,\"x \\\" y\"],\"b\":\"\\\\\"}"
        );
        let value: Value = serde_json::from_slice(&minify(text)).unwrap();
        assert_eq!(value, serde_json::from_slice::<Value>(text).unwrap());
    }

    #[test]
    fn jq_raw_reads_like_jq_r_with_empty() {
        let doc: Value =
            serde_json::json!({"s": "Oslo\n\n", "n": 12.5, "f": false, "z": null, "o": {"a": 1}});
        assert_eq!(jq_raw(doc.get("s")).as_deref(), Some("Oslo"));
        assert_eq!(jq_raw(doc.get("n")).as_deref(), Some("12.5"));
        assert_eq!(jq_raw(doc.get("o")).as_deref(), Some("{\"a\":1}"));
        assert_eq!(jq_raw(doc.get("f")), None);
        assert_eq!(jq_raw(doc.get("z")), None);
        assert_eq!(jq_raw(doc.get("missing")), None);
    }

    #[test]
    fn user_agents_must_be_printable_ascii() {
        // SAFETY of set_var: unit tests in this module are the only users of
        // these variable names.
        unsafe { std::env::set_var("FOAMY_WEATHER_TEST_UA", "agent/1.0 (x)") };
        assert_eq!(user_agent("FOAMY_WEATHER_TEST_UA"), "agent/1.0 (x)");
        unsafe { std::env::set_var("FOAMY_WEATHER_TEST_UA", "bad\r\nX-Injected: 1") };
        assert_eq!(user_agent("FOAMY_WEATHER_TEST_UA"), DEFAULT_USER_AGENT);
        unsafe { std::env::set_var("FOAMY_WEATHER_TEST_UA", "") };
        assert_eq!(user_agent("FOAMY_WEATHER_TEST_UA"), DEFAULT_USER_AGENT);
    }
}
