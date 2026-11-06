//! `geocode`: the place search (Panel.qml ran `curl -fsS --max-time 5`).

use std::ffi::OsString;
use std::io::Write;
use std::process::ExitCode;
use std::time::Duration;

use serde_json::Value;

use crate::http::{self, Error, Request};
use crate::util::{self, keys};

const HOST: &str = "geocoding-api.open-meteo.com";
const MAX_INPUT: u64 = 16 * 1024;
const MAX_QUERY: usize = 512;
const MAX_REPLY: usize = 256 * 1024;
const TIMEOUT: Duration = Duration::from_secs(5);

/// JavaScript's `encodeURIComponent`.
fn encode_component(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 3);
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// The query and the result language from `{"query":…,"language":…}`.
fn request(data: &[u8]) -> Option<(String, String)> {
    let doc = util::parse_one(data)?;
    let query = doc.get("query")?.as_str()?;
    if query.is_empty() || query.len() > MAX_QUERY {
        return None;
    }
    let language = doc
        .get("language")
        .and_then(Value::as_str)
        .filter(|l| l.len() == 2 && l.bytes().all(|b| b.is_ascii_lowercase()))
        .unwrap_or("en");
    Some((query.to_string(), language.to_string()))
}

pub fn main(args: &[OsString]) -> ExitCode {
    if !args.is_empty() {
        eprintln!("Usage: foamy-weather-helper geocode < {{\"query\":…,\"language\":…}}");
        return ExitCode::from(2);
    }
    let failure = |key: &str| {
        util::print_line(&serde_json::json!({ "error": key }).to_string());
        ExitCode::SUCCESS
    };
    // The typed place stays in stdin, never in argv.
    let Some((query, language)) = foamy_helper::io::read_stdin_limited(MAX_INPUT)
        .ok()
        .and_then(|data| request(&data))
    else {
        return failure(keys::SEARCH_FAILED);
    };
    let target = format!(
        "/v1/search?name={}&count=5&language={language}&format=json",
        encode_component(&query)
    );
    let user_agent = util::user_agent("WEATHER_LOCATION_USER_AGENT");
    let request = Request {
        host: HOST,
        target: &target,
        user_agent: &user_agent,
        if_modified_since: None,
        connect_timeout: TIMEOUT,
        timeout: TIMEOUT,
        limit: MAX_REPLY,
    };
    match http::get(&request) {
        Ok(response) if response.status != 304 => {
            let mut out = std::io::stdout().lock();
            let _ = out.write_all(&response.body);
            let _ = out.flush();
            ExitCode::SUCCESS
        }
        Err(Error::Unsupported) => failure(foamy_helper::tls::UNSUPPORTED),
        _ => failure(keys::SEARCH_FAILED),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_are_encoded_like_encode_uri_component() {
        assert_eq!(encode_component("Bø i Telemark"), "B%C3%B8%20i%20Telemark");
        assert_eq!(encode_component("a&b=c/d?e#f"), "a%26b%3Dc%2Fd%3Fe%23f");
        assert_eq!(encode_component("-_.!~*'()"), "-_.!~*'()");
    }

    #[test]
    fn requests_need_a_query() {
        assert_eq!(
            request(br#"{"query":"Oslo","language":"no"}"#),
            Some(("Oslo".into(), "no".into()))
        );
        assert_eq!(
            request(br#"{"query":"Oslo","language":"NOR"}"#),
            Some(("Oslo".into(), "en".into()))
        );
        assert_eq!(
            request(br#"{"query":"Oslo"}"#),
            Some(("Oslo".into(), "en".into()))
        );
        assert_eq!(request(br#"{"query":""}"#), None);
        assert_eq!(request(br#"{"query":5}"#), None);
        assert_eq!(
            request(format!(r#"{{"query":"{}"}}"#, "a".repeat(MAX_QUERY + 1)).as_bytes()),
            None
        );
        assert_eq!(request(b"Oslo"), None);
    }
}
