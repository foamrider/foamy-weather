//! `location --set | --migrate`: the searched place
//! (weather-location.sh).

use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use rustix::fs::{self as rfs, AtFlags, Mode, OFlags};
use rustix::io::Errno;
use serde_json::Value;

use crate::util;

const MAX_LOCATION: u64 = 64 * 1024;
const USAGE: &str = "Usage: foamy-weather-helper location --set < location.json | --migrate";

struct Paths {
    state_root: PathBuf,
    location: PathBuf,
    legacy: PathBuf,
}

fn paths() -> Paths {
    // The searched place is state, next to Omarchy's own weather.json.
    // Older versions kept it in config; --migrate moves it.
    let state_root = util::xdg("STATE", ".local/state").join("omarchy/settings");
    Paths {
        location: state_root.join("foamy-weather-location.json"),
        legacy: util::xdg("CONFIG", ".config").join("omarchy/weather-location.local.json"),
        state_root,
    }
}

/// The script's `read_location`: one JSON object with a non-empty string
/// `name` and numeric coordinates in range, as the line to store.
fn read_location(data: &[u8]) -> Option<String> {
    let doc = util::parse_one(data)?;
    let name = doc.get("name")?.as_str().filter(|n| !n.is_empty())?;
    let number = |key: &str, bound: f64| {
        doc.get(key)
            .filter(|v| v.is_number())
            .filter(|v| v.as_f64().is_some_and(|x| (-bound..=bound).contains(&x)))
            .map(Value::to_string)
    };
    let latitude = number("latitude", 90.0)?;
    let longitude = number("longitude", 180.0)?;
    Some(format!(
        "{{\"name\":{},\"latitude\":{latitude},\"longitude\":{longitude}}}",
        util::json_string(name)
    ))
}

fn read_location_file(path: &Path) -> Option<String> {
    util::read_regular(path, MAX_LOCATION).and_then(|c| read_location(&c.data))
}

fn is_file(path: &Path) -> bool {
    path.metadata().is_ok_and(|m| m.is_file())
}

/// Links an owner-only copy into place; fails if `path` exists (the
/// script's `ln -T`), so a concurrent `--set` is never replaced.
fn write_no_clobber(dir: &Path, path: &Path, data: &[u8]) -> io::Result<()> {
    let name = path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
    let dirfd = rfs::open(
        dir,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    let mut temp = None;
    for attempt in 0..64 {
        let candidate = format!(".foamy-weather-location.{}-{attempt}", std::process::id());
        let flags =
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        match rfs::openat(
            &dirfd,
            candidate.as_str(),
            flags,
            Mode::from_raw_mode(0o600),
        ) {
            Ok(fd) => {
                temp = Some((candidate, fd));
                break;
            }
            Err(Errno::EXIST) => continue,
            Err(error) => return Err(error.into()),
        }
    }
    let (temp, fd) = temp.ok_or(io::ErrorKind::AlreadyExists)?;
    let result = (|| -> io::Result<()> {
        rfs::fchmod(&fd, Mode::from_raw_mode(0o600))?;
        let mut file = File::from(fd);
        file.write_all(data)?;
        file.sync_all()?;
        rfs::linkat(&dirfd, temp.as_str(), &dirfd, name, AtFlags::empty())?;
        Ok(())
    })();
    let _ = rfs::unlinkat(&dirfd, temp.as_str(), AtFlags::empty());
    let _ = rfs::fsync(&dirfd);
    result
}

fn migrate(paths: &Paths) -> ExitCode {
    if !is_file(&paths.legacy) {
        return ExitCode::SUCCESS;
    }
    // A valid state file wins. The legacy file goes only when it holds the
    // same place (it was migrated already): a different one, say rewritten by
    // an older version after a downgrade, is the user's and stays, and so do
    // an invalid legacy file and anything next to an invalid state file.
    if util::exists(&paths.location) {
        if let Some(state) = read_location_file(&paths.location)
            && read_location_file(&paths.legacy).as_deref() == Some(state.as_str())
            && util::remove(&paths.legacy).is_err()
        {
            return ExitCode::FAILURE;
        }
        return ExitCode::SUCCESS;
    }
    let Some(location) = read_location_file(&paths.legacy) else {
        return ExitCode::SUCCESS;
    };
    if std::fs::create_dir_all(&paths.state_root).is_err() {
        return ExitCode::FAILURE;
    }
    let line = format!("{location}\n");
    // Lost a race with --set: its pick wins; the next run removes the legacy
    // file only if it holds the same place.
    if write_no_clobber(&paths.state_root, &paths.location, line.as_bytes()).is_err() {
        return ExitCode::SUCCESS;
    }
    if read_location_file(&paths.location).as_deref() != Some(location.as_str()) {
        return ExitCode::FAILURE;
    }
    match util::remove(&paths.legacy) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}

fn set(paths: &Paths) -> ExitCode {
    // The whole location stays in stdin, never in argv.
    let location = foamy_helper::io::read_stdin_limited(MAX_LOCATION)
        .ok()
        .and_then(|data| read_location(&data));
    let Some(location) = location else {
        eprintln!("Invalid location");
        return ExitCode::from(2);
    };
    let written = std::fs::create_dir_all(&paths.state_root)
        .and_then(|()| util::write_private(&paths.location, format!("{location}\n").as_bytes()));
    match written {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Could not save the location: {error}");
            ExitCode::FAILURE
        }
    }
}

pub fn main(args: &[OsString]) -> ExitCode {
    let paths = paths();
    let action = args.first().map(|a| a.as_os_str());
    match action.and_then(|a| a.to_str()) {
        Some("--migrate") if args.len() == 1 => migrate(&paths),
        Some("--set") if args.len() == 1 => set(&paths),
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locations_are_validated_and_normalised() {
        assert_eq!(
            read_location(
                br#"{"latitude":59.91,"extra":true,"name":"Old Town","longitude":10.75}"#
            )
            .as_deref(),
            Some(r#"{"name":"Old Town","latitude":59.91,"longitude":10.75}"#)
        );
        assert_eq!(
            read_location(b"{\"name\":\"Example\\nTown\",\"latitude\":-90,\"longitude\":180}")
                .as_deref(),
            Some(r#"{"name":"Example\nTown","latitude":-90,"longitude":180}"#)
        );
        for bad in [
            &b""[..],
            b"{broken",
            b"{}",
            b"[]",
            br#"{"name":"","latitude":1,"longitude":2}"#,
            br#"{"name":1,"latitude":1,"longitude":2}"#,
            br#"{"name":"x","latitude":"1","longitude":2}"#,
            br#"{"name":"x","latitude":91,"longitude":2}"#,
            br#"{"name":"x","latitude":1,"longitude":-180.5}"#,
            br#"{"name":"x","latitude":1}"#,
            br#"{"name":"x","latitude":1,"longitude":2} {"name":"x","latitude":1,"longitude":2}"#,
        ] {
            assert_eq!(read_location(bad), None, "{}", String::from_utf8_lossy(bad));
        }
    }
}
