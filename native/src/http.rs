//! HTTPS GET: what the scripts asked curl for (`--fail --compressed
//! --connect-timeout --max-time`, proxies from the environment), with every
//! socket under an absolute deadline.

use std::io::{self, BufRead, BufReader, ErrorKind, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use flate2::read::{GzDecoder, ZlibDecoder};
use foamy_helper::net::{self, DeadlineStream};
use foamy_helper::tls::{self, TlsError, rustls};
use rustls::pki_types::ServerName;
use rustls::{ClientConnection, StreamOwned};

/// Test-only: every direct connection goes to this loopback `ip:port`.
pub const TEST_CONNECT: &str = "FOAMY_WEATHER_TEST_CONNECT";

const MAX_LINE: usize = 16 * 1024;
const MAX_HEAD: usize = 64 * 1024;
const MAX_HEADERS: usize = 100;
/// Raw bytes still read after a compressed body ended, to see its framing end.
const MAX_TRAILING: u64 = 64 * 1024;

/// One GET.
pub struct Request<'a> {
    /// The host name: TLS is verified for it, it is the `Host` header.
    pub host: &'a str,
    /// Path and query.
    pub target: &'a str,
    pub user_agent: &'a str,
    /// Sent as `If-Modified-Since` (the caller checked it is a plain date).
    pub if_modified_since: Option<&'a str>,
    /// DNS, TCP, the proxy tunnel and the TLS handshake (curl's
    /// `--connect-timeout`), within `timeout`.
    pub connect_timeout: Duration,
    /// Everything (curl's `--max-time`).
    pub timeout: Duration,
    /// Decoded body bytes; one more is [`Error::TooLarge`].
    pub limit: usize,
}

/// A response below 400.
#[derive(Debug)]
pub struct Response {
    pub status: u16,
    headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    /// The last value of header `name` (the scripts read curl's header
    /// dump with awk, where the last line wins).
    pub fn header(&self, name: &str) -> Option<&str> {
        header(&self.headers, name)
    }
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .rev()
        .find(|(n, _)| n.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// This CPU lacks the instructions Graviola needs (`tls::UNSUPPORTED`).
    Unsupported,
    /// The connect or overall deadline passed.
    Timeout,
    /// Status 400 or above (curl `--fail`).
    Status(u16),
    /// The decoded body is larger than the limit.
    TooLarge,
    /// DNS, connection, proxy, TLS, framing or decoding failed.
    Failed(String),
}

fn failed(what: impl std::fmt::Display) -> Error {
    Error::Failed(what.to_string())
}

fn io_error(error: io::Error) -> Error {
    if net::is_deadline(&error) {
        Error::Timeout
    } else {
        failed(error)
    }
}

fn remaining(deadline: Instant) -> Result<Duration, Error> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        Err(Error::Timeout)
    } else {
        Ok(left)
    }
}

/// GET `https://<host><target>`.
pub fn get(request: &Request) -> Result<Response, Error> {
    let config = tls::client_config().map_err(|error| match error {
        TlsError::UnsupportedCpu => Error::Unsupported,
        other => failed(other),
    })?;
    let start = Instant::now();
    let deadline = start + request.timeout;
    let connect_deadline = (start + request.connect_timeout).min(deadline);
    let tcp = match proxy_for(request.host)? {
        Some(proxy) => {
            let tcp = connect_host(&proxy.host, proxy.port, connect_deadline)?;
            tunnel(tcp, &proxy, request, connect_deadline)?
        }
        None => connect_direct(request.host, connect_deadline)?,
    };
    let _ = tcp.set_nodelay(true);
    let name = ServerName::try_from(request.host.to_string()).map_err(failed)?;
    let connection = ClientConnection::new(config, name).map_err(failed)?;
    let mut stream = StreamOwned::new(connection, DeadlineStream::new(tcp, connect_deadline));
    while stream.conn.is_handshaking() {
        match stream.conn.complete_io(&mut stream.sock) {
            Ok((0, 0)) => return Err(failed("connection closed during the TLS handshake")),
            Ok(_) => {}
            Err(error) => return Err(io_error(error)),
        }
    }
    stream.sock.set_deadline(deadline);
    exchange(stream, request)
}

/// The request and response on an established stream (TLS in production;
/// any stream in unit tests).
fn exchange<S: Read + Write>(mut stream: S, request: &Request) -> Result<Response, Error> {
    let mut head = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {}\r\nAccept: */*\r\n\
         Accept-Encoding: gzip, deflate\r\nConnection: close\r\n",
        request.target, request.host, request.user_agent
    );
    if let Some(date) = request.if_modified_since {
        head.push_str(&format!("If-Modified-Since: {date}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).map_err(io_error)?;
    stream.flush().map_err(io_error)?;
    read_response(BufReader::new(stream), request.limit)
}

fn read_response<R: BufRead>(mut reader: R, limit: usize) -> Result<Response, Error> {
    let mut budget = MAX_HEAD;
    let mut interim = 0;
    let (status, headers) = loop {
        let status = read_status(&mut reader, &mut budget)?;
        let headers = read_headers(&mut reader, &mut budget)?;
        match status {
            101 => return Err(failed("unexpected protocol switch")),
            100..=199 if interim < 8 => interim += 1,
            100..=199 => return Err(failed("too many interim responses")),
            _ => break (status, headers),
        }
    };
    if status >= 400 {
        return Err(Error::Status(status));
    }
    let framing = framing(status, &headers)?;
    let mut body = Body {
        inner: reader,
        framing,
        chunk_left: 0,
        after_chunk: false,
    };
    let decoded = decode(&mut body, &headers, limit)?;
    Ok(Response {
        status,
        headers,
        body: decoded,
    })
}

/// One line of the response head, `\n` included; refuses an overlong line
/// and a head over `MAX_HEAD` bytes.
fn read_line<R: BufRead>(reader: &mut R, budget: &mut usize) -> Result<Vec<u8>, Error> {
    let max = MAX_LINE.min(*budget);
    let mut line = Vec::new();
    reader
        .by_ref()
        .take(max as u64)
        .read_until(b'\n', &mut line)
        .map_err(io_error)?;
    if !line.ends_with(b"\n") {
        return Err(failed(if line.len() == max {
            "response head too large"
        } else {
            "connection closed in the response head"
        }));
    }
    *budget -= line.len();
    let end = line.len() - if line.ends_with(b"\r\n") { 2 } else { 1 };
    line.truncate(end);
    Ok(line)
}

fn read_status<R: BufRead>(reader: &mut R, budget: &mut usize) -> Result<u16, Error> {
    let line = read_line(reader, budget)?;
    let text = String::from_utf8_lossy(&line);
    let mut parts = text.splitn(3, ' ');
    let version = parts.next().unwrap_or("");
    let code = parts.next().unwrap_or("");
    if !version.starts_with("HTTP/1.")
        || code.len() != 3
        || !code.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(failed("malformed status line"));
    }
    let code: u16 = code.parse().map_err(failed)?;
    if code < 100 {
        return Err(failed("malformed status line"));
    }
    Ok(code)
}

fn read_headers<R: BufRead>(
    reader: &mut R,
    budget: &mut usize,
) -> Result<Vec<(String, String)>, Error> {
    let mut headers: Vec<(String, String)> = Vec::new();
    loop {
        let line = read_line(reader, budget)?;
        if line.is_empty() {
            return Ok(headers);
        }
        let text = String::from_utf8_lossy(&line).into_owned();
        if text.starts_with([' ', '\t']) {
            // An obsolete folded continuation of the previous header.
            let last = headers
                .last_mut()
                .ok_or_else(|| failed("malformed header"))?;
            last.1.push(' ');
            last.1.push_str(text.trim_matches([' ', '\t']));
            continue;
        }
        let (name, value) = text
            .split_once(':')
            .ok_or_else(|| failed("malformed header"))?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(failed("malformed header"));
        }
        if headers.len() == MAX_HEADERS {
            return Err(failed("too many headers"));
        }
        headers.push((
            name.to_string(),
            value.trim_matches([' ', '\t']).to_string(),
        ));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Framing {
    Empty,
    Length(u64),
    Chunked,
    Close,
}

/// RFC 9112 §6.3: no body for 1xx, 204 and 304; chunked when it is the
/// final transfer coding; else Content-Length; else until the server
/// closes (with TLS close_notify: a bare TCP close is a truncation).
fn framing(status: u16, headers: &[(String, String)]) -> Result<Framing, Error> {
    if status == 204 || status == 304 {
        return Ok(Framing::Empty);
    }
    let codings: Vec<String> = headers
        .iter()
        .filter(|(n, _)| n.eq_ignore_ascii_case("transfer-encoding"))
        .flat_map(|(_, v)| v.split(','))
        .map(|c| c.trim().to_ascii_lowercase())
        .filter(|c| !c.is_empty())
        .collect();
    if !codings.is_empty() {
        if codings == ["chunked"] {
            return Ok(Framing::Chunked);
        }
        return Err(failed("unsupported transfer coding"));
    }
    let mut length = None;
    for (_, value) in headers
        .iter()
        .filter(|(n, _)| n.eq_ignore_ascii_case("content-length"))
    {
        for part in value.split(',') {
            let part = part.trim();
            if part.is_empty() || part.len() > 19 || !part.bytes().all(|b| b.is_ascii_digit()) {
                return Err(failed("malformed Content-Length"));
            }
            let value: u64 = part.parse().map_err(failed)?;
            if length.is_some_and(|l| l != value) {
                return Err(failed("conflicting Content-Length"));
            }
            length = Some(value);
        }
    }
    Ok(length.map_or(Framing::Close, Framing::Length))
}

/// The message body as sent (before content decoding).
struct Body<R> {
    inner: R,
    framing: Framing,
    chunk_left: u64,
    after_chunk: bool,
}

fn truncated() -> io::Error {
    io::Error::new(
        ErrorKind::UnexpectedEof,
        "transfer closed before the body ended",
    )
}

fn bad_chunk() -> io::Error {
    io::Error::new(ErrorKind::InvalidData, "malformed chunked body")
}

impl<R: BufRead> Body<R> {
    fn chunk_line(&mut self) -> io::Result<Vec<u8>> {
        let mut line = Vec::new();
        self.inner
            .by_ref()
            .take(MAX_LINE as u64)
            .read_until(b'\n', &mut line)?;
        if !line.ends_with(b"\n") {
            return Err(if line.len() == MAX_LINE {
                bad_chunk()
            } else {
                truncated()
            });
        }
        line.pop();
        if line.ends_with(b"\r") {
            line.pop();
        }
        Ok(line)
    }

    /// Starts the next chunk; false after the last one (and its trailers).
    fn next_chunk(&mut self) -> io::Result<bool> {
        if self.after_chunk {
            if !self.chunk_line()?.is_empty() {
                return Err(bad_chunk());
            }
            self.after_chunk = false;
        }
        let line = self.chunk_line()?;
        let size = line.split(|&b| b == b';').next().unwrap_or(&[]);
        let size = std::str::from_utf8(size)
            .map_err(|_| bad_chunk())?
            .trim_matches([' ', '\t']);
        if size.is_empty() || size.len() > 15 || !size.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(bad_chunk());
        }
        let size = u64::from_str_radix(size, 16).map_err(|_| bad_chunk())?;
        if size == 0 {
            for _ in 0..=MAX_HEADERS {
                if self.chunk_line()?.is_empty() {
                    self.framing = Framing::Empty;
                    return Ok(false);
                }
            }
            return Err(bad_chunk());
        }
        self.chunk_left = size;
        Ok(true)
    }

    fn finished(&self) -> bool {
        self.framing == Framing::Empty
    }
}

impl<R: BufRead> Read for Body<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        match self.framing {
            Framing::Empty => Ok(0),
            Framing::Close => {
                let read = self.inner.read(buf)?;
                if read == 0 {
                    self.framing = Framing::Empty;
                }
                Ok(read)
            }
            Framing::Length(0) => {
                self.framing = Framing::Empty;
                Ok(0)
            }
            Framing::Length(left) => {
                let want = buf.len().min(left.min(usize::MAX as u64) as usize);
                let read = self.inner.read(&mut buf[..want])?;
                if read == 0 {
                    return Err(truncated());
                }
                let left = left - read as u64;
                self.framing = if left == 0 {
                    Framing::Empty
                } else {
                    Framing::Length(left)
                };
                Ok(read)
            }
            Framing::Chunked => {
                if self.chunk_left == 0 && !self.next_chunk()? {
                    return Ok(0);
                }
                let want = buf
                    .len()
                    .min(self.chunk_left.min(usize::MAX as u64) as usize);
                let read = self.inner.read(&mut buf[..want])?;
                if read == 0 {
                    return Err(truncated());
                }
                self.chunk_left -= read as u64;
                if self.chunk_left == 0 {
                    self.after_chunk = true;
                }
                Ok(read)
            }
        }
    }
}

/// Reads `limit + 1` decoded bytes at most (curl `--compressed | head -c`).
fn read_limited<R: Read>(reader: R, limit: usize) -> Result<Vec<u8>, Error> {
    let mut data = Vec::new();
    reader
        .take(limit as u64 + 1)
        .read_to_end(&mut data)
        .map_err(io_error)?;
    if data.len() > limit {
        return Err(Error::TooLarge);
    }
    Ok(data)
}

/// The decoded body. A compressed body must also end where its framing
/// says (a transfer cut after the compressed data is still a truncation).
fn decode<R: BufRead>(
    body: &mut Body<R>,
    headers: &[(String, String)],
    limit: usize,
) -> Result<Vec<u8>, Error> {
    let coding: Vec<String> = headers
        .iter()
        .filter(|(n, _)| n.eq_ignore_ascii_case("content-encoding"))
        .flat_map(|(_, v)| v.split(','))
        .map(|c| c.trim().to_ascii_lowercase())
        .filter(|c| !c.is_empty() && c != "identity")
        .collect();
    let data = match coding.as_slice() {
        [] => return read_limited(&mut *body, limit),
        [gzip] if gzip == "gzip" || gzip == "x-gzip" => {
            read_limited(GzDecoder::new(&mut *body), limit)?
        }
        [deflate] if deflate == "deflate" => read_limited(ZlibDecoder::new(&mut *body), limit)?,
        _ => return Err(failed("unsupported content coding")),
    };
    io::copy(&mut body.by_ref().take(MAX_TRAILING), &mut io::sink()).map_err(io_error)?;
    if !body.finished() {
        return Err(failed("data after the compressed body"));
    }
    Ok(data)
}

fn resolve(host: &str, port: u16, deadline: Instant) -> Result<Vec<SocketAddr>, Error> {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = bare.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, port)]);
    }
    // getaddrinfo cannot be interrupted: it runs on its own thread and the
    // request stops waiting at the deadline.
    let (sender, receiver) = mpsc::channel();
    let name = host.to_string();
    thread::spawn(move || {
        let answer = (name.as_str(), port)
            .to_socket_addrs()
            .map(|addresses| addresses.collect::<Vec<_>>());
        let _ = sender.send(answer);
    });
    match receiver.recv_timeout(remaining(deadline)?) {
        Ok(Ok(addresses)) if !addresses.is_empty() => Ok(addresses),
        Ok(_) => Err(failed("could not resolve the host")),
        Err(_) => Err(Error::Timeout),
    }
}

fn connect_addresses(addresses: &[SocketAddr], deadline: Instant) -> Result<TcpStream, Error> {
    let mut last = failed("no address to connect to");
    for address in addresses {
        match TcpStream::connect_timeout(address, remaining(deadline)?) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = io_error(error),
        }
    }
    Err(last)
}

fn connect_host(host: &str, port: u16, deadline: Instant) -> Result<TcpStream, Error> {
    connect_addresses(&resolve(host, port, deadline)?, deadline)
}

fn connect_direct(host: &str, deadline: Instant) -> Result<TcpStream, Error> {
    match std::env::var_os(TEST_CONNECT) {
        None => connect_host(host, 443, deadline),
        Some(target) => {
            let address: SocketAddr = target
                .to_str()
                .and_then(|t| t.parse().ok())
                .filter(|a: &SocketAddr| a.ip().is_loopback())
                .ok_or_else(|| failed(format!("{TEST_CONNECT} must be a loopback ip:port")))?;
            connect_addresses(&[address], deadline)
        }
    }
}

/// An HTTP proxy for CONNECT.
#[derive(Debug, PartialEq, Eq)]
struct Proxy {
    host: String,
    port: u16,
    /// `Basic …` for `user:password@` in the proxy URL.
    authorization: Option<String>,
}

fn env_value(names: &[&str]) -> Option<String> {
    names
        .iter()
        .find_map(|name| std::env::var(name).ok().filter(|v| !v.trim().is_empty()))
}

/// curl's choice for an https URL: `https_proxy`, `HTTPS_PROXY`, then
/// `all_proxy`, `ALL_PROXY`, unless `no_proxy`/`NO_PROXY` names the host.
fn proxy_for(host: &str) -> Result<Option<Proxy>, Error> {
    let Some(url) = env_value(&["https_proxy", "HTTPS_PROXY"])
        .or_else(|| env_value(&["all_proxy", "ALL_PROXY"]))
    else {
        return Ok(None);
    };
    if bypass(
        host,
        &env_value(&["no_proxy", "NO_PROXY"]).unwrap_or_default(),
    ) {
        return Ok(None);
    }
    parse_proxy(&url).map(Some)
}

/// curl's `no_proxy`: `*` alone matches every host; otherwise a comma
/// (or blank) separated list of names, each matching itself and its
/// subdomains (a leading dot is optional).
fn bypass(host: &str, list: &str) -> bool {
    if list.trim() == "*" {
        return true;
    }
    let host = host.trim_end_matches('.');
    list.split([',', ' ', '\t'])
        .map(|entry| entry.trim().trim_start_matches('.').trim_end_matches('.'))
        .filter(|entry| !entry.is_empty())
        .any(|entry| {
            host.eq_ignore_ascii_case(entry)
                || (host.len() > entry.len()
                    && host.as_bytes()[host.len() - entry.len() - 1] == b'.'
                    && host[host.len() - entry.len()..].eq_ignore_ascii_case(entry))
        })
}

fn percent_decode(text: &str) -> Result<String, Error> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text
                .get(i + 1..i + 3)
                .and_then(|h| u8::from_str_radix(h, 16).ok())
                .ok_or_else(|| failed("malformed proxy credentials"))?;
            out.push(hex);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(failed)
}

fn base64(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let n = chunk.iter().fold(0u32, |n, &b| n << 8 | b as u32) << (8 * (3 - chunk.len()));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// `[http://][user[:password]@]host[:port][/…]`; curl's default proxy port
/// is 1080. Other schemes (https, socks…) are refused rather than ignored,
/// so a request never silently bypasses a configured proxy.
fn parse_proxy(url: &str) -> Result<Proxy, Error> {
    let url = url.trim();
    let rest = match url.split_once("://") {
        Some((scheme, rest)) if scheme.eq_ignore_ascii_case("http") => rest,
        Some(_) => return Err(failed("unsupported proxy scheme")),
        None => url,
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let (credentials, address) = match authority.rsplit_once('@') {
        Some((credentials, address)) => (Some(credentials), address),
        None => (None, authority),
    };
    let (host, port) = if let Some(after) = address.strip_prefix('[') {
        let (host, tail) = after
            .split_once(']')
            .ok_or_else(|| failed("malformed proxy"))?;
        (host, tail.strip_prefix(':'))
    } else {
        match address.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (address, None),
        }
    };
    let port = match port {
        None | Some("") => 1080,
        Some(port) => port.parse().map_err(|_| failed("malformed proxy port"))?,
    };
    if host.is_empty() || port == 0 {
        return Err(failed("malformed proxy"));
    }
    let authorization = credentials
        .map(|credentials| -> Result<String, Error> {
            let (user, password) = credentials.split_once(':').unwrap_or((credentials, ""));
            let pair = format!("{}:{}", percent_decode(user)?, percent_decode(password)?);
            Ok(format!("Basic {}", base64(pair.as_bytes())))
        })
        .transpose()?;
    Ok(Proxy {
        host: host.to_string(),
        port,
        authorization,
    })
}

/// `CONNECT host:443` through the proxy. The reply is read a byte at a
/// time so nothing of the TLS stream that follows is consumed here.
fn tunnel(
    tcp: TcpStream,
    proxy: &Proxy,
    request: &Request,
    deadline: Instant,
) -> Result<TcpStream, Error> {
    let mut stream = DeadlineStream::new(tcp, deadline);
    let mut head = format!(
        "CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\nUser-Agent: {}\r\n",
        request.user_agent,
        host = request.host
    );
    if let Some(authorization) = &proxy.authorization {
        head.push_str(&format!("Proxy-Authorization: {authorization}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).map_err(io_error)?;
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    while !(reply.ends_with(b"\r\n\r\n") || reply.ends_with(b"\n\n")) {
        if reply.len() >= MAX_HEAD {
            return Err(failed("proxy reply too large"));
        }
        if stream.read(&mut byte).map_err(io_error)? == 0 {
            return Err(failed("proxy closed the connection"));
        }
        reply.push(byte[0]);
    }
    let mut budget = MAX_HEAD;
    let status = read_status(&mut &reply[..], &mut budget)?;
    if !(200..300).contains(&status) {
        return Err(failed(format!("proxy refused the tunnel ({status})")));
    }
    Ok(stream.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::net::TcpListener;

    fn response(raw: &[u8], limit: usize) -> Result<Response, Error> {
        read_response(Cursor::new(raw.to_vec()), limit)
    }

    fn gzip(data: &[u8]) -> Vec<u8> {
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn length_chunked_and_close_framing() {
        let ok = response(
            b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA",
            10,
        )
        .unwrap();
        assert_eq!(ok.body, b"hello");
        let chunked = response(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;x=y\r\nhel\r\n2\r\nlo\r\n0\r\nTrailer: 1\r\n\r\n",
            10,
        )
        .unwrap();
        assert_eq!(chunked.body, b"hello");
        let close = response(b"HTTP/1.0 200 OK\r\n\r\nhello", 10).unwrap();
        assert_eq!(close.body, b"hello");
        let empty = response(
            b"HTTP/1.1 304 Not Modified\r\nContent-Length: 9\r\n\r\n",
            10,
        )
        .unwrap();
        assert_eq!((empty.status, empty.body.len()), (304, 0));
        let interim = response(
            b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\nContent-Length: 2\n\nok",
            10,
        )
        .unwrap();
        assert_eq!(interim.body, b"ok");
    }

    #[test]
    fn truncated_and_malformed_bodies_fail() {
        for raw in [
            &b"HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nhello"[..],
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloX\r\n0\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
            b"HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello",
            b"HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: 5\r\n\r\nhello",
            b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n",
            b"HTTP/2 200\r\n\r\n",
            b"garbage\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nBad Header\r\n\r\n",
        ] {
            assert!(
                matches!(response(raw, 100), Err(Error::Failed(_))),
                "{}",
                String::from_utf8_lossy(raw)
            );
        }
        assert_eq!(
            response(b"HTTP/1.1 503 Busy\r\n\r\n", 10).unwrap_err(),
            Error::Status(503)
        );
        assert_eq!(
            response(b"HTTP/1.1 404 No\r\nContent-Length: 0\r\n\r\n", 10).unwrap_err(),
            Error::Status(404)
        );
    }

    #[test]
    fn limits_apply_to_decoded_bytes() {
        let exact = response(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", 5).unwrap();
        assert_eq!(exact.body, b"hello");
        assert_eq!(
            response(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello!", 5).unwrap_err(),
            Error::TooLarge
        );
        let big = vec![b' '; 100_000];
        let mut raw = format!(
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\n\r\n",
            gzip(&big).len()
        )
        .into_bytes();
        raw.extend(gzip(&big));
        assert_eq!(response(&raw, 99_999).unwrap_err(), Error::TooLarge);
        assert_eq!(response(&raw, 100_000).unwrap().body, big);
        // A gzip member cut by the end of the transfer.
        let packed = gzip(b"hello world");
        let mut cut = format!(
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\n\r\n",
            packed.len() + 10
        )
        .into_bytes();
        cut.extend(&packed);
        assert!(matches!(response(&cut, 100), Err(Error::Failed(_))));
        // Chunked gzip.
        let mut chunked =
            b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n"
                .to_vec();
        for part in packed.chunks(4) {
            chunked.extend(format!("{:x}\r\n", part.len()).as_bytes());
            chunked.extend(part);
            chunked.extend(b"\r\n");
        }
        chunked.extend(b"0\r\n\r\n");
        assert_eq!(response(&chunked, 100).unwrap().body, b"hello world");
    }

    #[test]
    fn head_limits() {
        let mut long = b"HTTP/1.1 200 OK\r\nX: ".to_vec();
        long.extend(vec![b'a'; MAX_LINE]);
        long.extend(b"\r\n\r\n");
        assert!(matches!(response(&long, 10), Err(Error::Failed(_))));
        let mut many = b"HTTP/1.1 200 OK\r\n".to_vec();
        for i in 0..=MAX_HEADERS {
            many.extend(format!("X-{i}: 1\r\n").as_bytes());
        }
        many.extend(b"Content-Length: 0\r\n\r\n");
        assert!(matches!(response(&many, 10), Err(Error::Failed(_))));
    }

    #[test]
    fn headers_last_value_wins() {
        let r = response(
            b"HTTP/1.1 200 OK\r\nExpires: a\r\nexpires:  b \r\nContent-Length: 0\r\n\r\n",
            0,
        )
        .unwrap();
        assert_eq!(r.header("EXPIRES"), Some("b"));
        assert_eq!(r.header("Last-Modified"), None);
    }

    #[test]
    fn requests_carry_the_agent_and_validator() {
        let mut wire = Vec::new();
        struct Duplex<'a>(Cursor<&'a [u8]>, &'a mut Vec<u8>);
        impl Read for Duplex<'_> {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                self.0.read(buf)
            }
        }
        impl Write for Duplex<'_> {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                self.1.write(buf)
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let request = Request {
            host: "api.met.no",
            target: "/x?lat=1.000&lon=2.000",
            user_agent: "agent/1",
            if_modified_since: Some("Thu, 29 Oct 2026 10:00:00 GMT"),
            connect_timeout: Duration::from_secs(1),
            timeout: Duration::from_secs(1),
            limit: 10,
        };
        let reply = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
        let r = exchange(Duplex(Cursor::new(reply), &mut wire), &request).unwrap();
        assert_eq!(r.body, b"ok");
        assert_eq!(
            String::from_utf8(wire).unwrap(),
            "GET /x?lat=1.000&lon=2.000 HTTP/1.1\r\nHost: api.met.no\r\nUser-Agent: agent/1\r\n\
             Accept: */*\r\nAccept-Encoding: gzip, deflate\r\nConnection: close\r\n\
             If-Modified-Since: Thu, 29 Oct 2026 10:00:00 GMT\r\n\r\n"
        );
    }

    #[test]
    fn a_trickling_server_hits_the_absolute_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let _ = socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n");
            for _ in 0..40 {
                thread::sleep(Duration::from_millis(50));
                if socket.write_all(b"x").is_err() {
                    break;
                }
            }
        });
        let request = Request {
            host: "localhost",
            target: "/",
            user_agent: "t",
            if_modified_since: None,
            connect_timeout: Duration::from_millis(500),
            timeout: Duration::from_millis(500),
            limit: 2000,
        };
        let started = Instant::now();
        let tcp = TcpStream::connect(address).unwrap();
        let stream = DeadlineStream::new(tcp, started + request.timeout);
        assert_eq!(exchange(stream, &request).unwrap_err(), Error::Timeout);
        let elapsed = started.elapsed();
        assert!(elapsed < Duration::from_millis(900), "{elapsed:?}");
        server.join().unwrap();
    }

    #[test]
    fn proxies_parse_like_curl() {
        assert_eq!(
            parse_proxy("http://proxy.example:3128/").unwrap(),
            Proxy {
                host: "proxy.example".into(),
                port: 3128,
                authorization: None
            }
        );
        assert_eq!(parse_proxy("proxy.example").unwrap().port, 1080);
        assert_eq!(
            parse_proxy("HTTP://us%40er:p%3Ass@[::1]:8080").unwrap(),
            Proxy {
                host: "::1".into(),
                port: 8080,
                authorization: Some(format!("Basic {}", base64(b"us@er:p:ss"))),
            }
        );
        assert_eq!(
            base64(b"Aladdin:open sesame"),
            "QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
        );
        assert_eq!(base64(b"a"), "YQ==");
        assert_eq!(base64(b"ab"), "YWI=");
        for bad in [
            "socks5://h:1",
            "https://h:1",
            "http://:1",
            "http://h:x",
            "http://h:0",
            "http://%zz@h",
        ] {
            assert!(parse_proxy(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn no_proxy_matches_names_and_subdomains() {
        assert!(bypass("api.met.no", "*"));
        assert!(bypass("api.met.no", "example.org, .met.no"));
        assert!(bypass("api.met.no", "met.no"));
        assert!(bypass("API.MET.NO", "api.met.no"));
        assert!(!bypass("api.met.no", "et.no"));
        assert!(!bypass("api.met.no", "example.org,*"));
        assert!(!bypass("api.met.no", ""));
    }
}
