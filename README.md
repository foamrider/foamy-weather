# Foamy Weather

Current weather and a three-day forecast.

![Foamy Weather popup with current conditions, a three-day forecast and the hourly forecast](preview.png)

## Install

Requires Omarchy 4.5 (it also loads on 4.0, in English), Bash, and, for
pasting into the location search, `jq`, GNU coreutils and `wl-paste`
(wl-clipboard). Forecasts, location search and place names come from the
plugin's bundled helper, `bin/<arch>/foamy-weather-helper` (static binaries for
x86-64 and AArch64 Linux; no `curl`, Python or other runtime). Its HTTPS needs
AES, carry-less multiply, AVX2, BMI2 and ADX on x86-64 (Intel Broadwell, AMD
Zen or newer), or the crypto extensions on ARMv8 (a Raspberry Pi 5, not a
Pi 4); without them the widget says HTTPS isn't supported on this CPU instead
of loading weather. Internet access is required for forecasts and location
search; `https_proxy`/`all_proxy` (HTTP proxies) and `no_proxy` are honoured.
For automatic location, install GeoClue (`geoclue`; its `where-am-i` demo is
used). Disable another weather widget before enabling this one.

```sh
omarchy plugin add https://github.com/foamrider/foamy-weather.git --enable
```

## Use

1. Left-click the widget and open Settings (the cog, or `s`).
2. Search for a location and select a result, or turn on **Use location data**.
3. Choose units, and whether to animate the background.

Left-click opens the forecast, middle-click refreshes, and right-click shows a
summary notification. Select a day to see its hourly forecast.

Keyboard: arrow keys or `h`/`j`/`k`/`l` move one cursor over the day cards,
refresh and settings (moving onto a day selects it); Enter activates (with
nothing selected it opens Settings), `s` opens Settings, `r` refreshes, Esc
closes or leaves Settings, Tab and Shift+Tab switch to the next bar panel.
IPC: `omarchy-shell foamy.weather open|close|toggle|edit|refresh` (`show` and
`hide` are aliases of `open` and `close`).

The header shows the place, the temperature with the condition and today's
range, and a strip with wind, humidity, the next hour's precipitation and the
UV index, over an animated sky drawn from the current MET conditions (clouds
drift with the wind; calm weather and fog still move slowly).

When the location changes, the previous forecast stays visible, labelled with
its own place, until the new one arrives. The animated sky runs only while the
popup is open; with Omarchy's animations off (reduced motion) it is a still
image, and with CPU rendering or the `animations` setting off the plain header
is shown.

## Settings

Settings live in the widget's entry in `shell.json`. The popup sets the first
three; set the others with `omarchy bar set foamy.weather <key> <json> --json`.
A stored value outside these rules (a string, or out of range) reads as the
default, as the popup would refuse it.

| Key | Default | Meaning |
|---|---|---|
| `units` | `"metric"` | `"metric"` (°C, km/h, mm) or `"imperial"` (°F, mph, in) |
| `automaticLocation` | `false` | Use GeoClue for the location instead of the searched place |
| `animations` | `true` | Animated sky behind the current conditions |
| `refreshMinutes` | `30` | Forecast refresh interval, 5–1440 minutes |
| `locationRefreshMinutes` | `15` | Automatic-location refresh interval, 5–1440 minutes |
| `requestUserAgent` | `""` | User-Agent for MET Norway and OpenStreetMap requests (printable ASCII, 200 characters); empty or blank uses `foamy-weather/<version> (+repository URL)` |

The searched location is stored, owner-only, in
`~/.local/state/omarchy/settings/foamy-weather-location.json` (under
`$XDG_STATE_HOME` when set); without one, the stock weather location
(`weather.json` in the same directory) is used. Earlier versions kept it in
`~/.config/omarchy/weather-location.local.json`: when the widget starts, a
valid file there is copied to the new place, checked, and then removed. If
both exist the new file wins and the old one is removed; an invalid old file is
left alone.

## Privacy and network use

- Automatic positions are rounded to two decimals (about 1 km) before they are
  used, cached or sent anywhere. OpenStreetMap's Nominatim receives only that
  rounded position, at most once per new place per week, to name it.
- MET Norway receives coordinates rounded to three decimals (about 100 m).
- Coordinates and searched place names reach the helper through stdin, never
  process arguments. Cache names use opaque hashes; caches are owner-only.
  The current automatic position is kept in `$XDG_RUNTIME_DIR` only; without
  a private runtime directory automatic location reports an error instead of
  using `/tmp`.
- Forecasts follow MET's terms: the `Expires` header decides when to ask
  again (30 minutes when absent), refreshes send `If-Modified-Since`, and a
  forced refresh (middle-click, the refresh button) waits at least 60 seconds
  between downloads. Requests identify the plugin with a User-Agent.
- Forecast responses are limited to 2 MiB and each sunrise response to 64 KiB
  after decompression (place names and search results to 256 KiB); invalid
  or oversized responses are rejected and a valid cached forecast stays
  available. Each request has a fixed deadline (3 seconds to connect; 10
  seconds for a forecast, 8 for sunrise or a place name, 5 for a search).
  Requests wait briefly after the network connects and retry temporary
  failures up to three times with increasing delays.
- One shell runs one set of requests and timers, however many monitors show
  the bar.
- Location-search paste is limited to 16 KiB and two seconds.

## Remove

```sh
omarchy plugin remove foamy.weather
```

When removing an enabled replacement, Omarchy restores `omarchy.weather`.
Location settings, forecast preferences, and cached forecasts
(`~/.cache/omarchy-weather/`) remain on disk.
Some settings are shared with the stock weather plugin; retain them if you
intend to use it. GeoClue remains installed.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

Weather: [MET Norway](https://www.met.no/), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Search: [Open-Meteo](https://open-meteo.com/) / GeoNames.
Automatic location names: [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).

Code: [MIT](LICENSE). Third-party notices:
[Omarchy](LICENSE-OMARCHY), [Atmosphere](LICENSE-ATMOSPHERE),
[Meteocons](LICENSE-METEOCONS), and [Lucide](kit/LICENSE-LUCIDE).
Shared components: [foamy-kit](https://github.com/foamrider/foamy-kit) (MIT), copied into `kit/`.

Provided **as is**, without warranty or guaranteed support. Use at your own risk.

Language follows **Omarchy → Setup → Language** on Omarchy 4.5 (English and
Norwegian catalogs; others fall back to English). Omarchy 4.0 displays the
plugin in English.

## Development

`kit/` holds shared components copied from [foamy-kit](https://github.com/foamrider/foamy-kit); edit them there, not here.

The helper's source is `native/` (Rust; its contract is the doc comment at the
top of `native/src/main.rs`). Rebuild both binaries and `native/native.pin`
with foamy-kit's build tool after any change there, in `kit/rust/` or in
`Cargo.lock`, and commit them together:

```sh
export CARGO_TARGET_DIR=~/.cache/foamy-native/foamy-weather   # never inside the plugin
~/GitHub/Personal/foamy-kit/tools/build-native.sh . --test    # fmt, clippy, unit tests
~/GitHub/Personal/foamy-kit/tools/build-native.sh .           # bin/x86_64, bin/aarch64, native.pin
~/GitHub/Personal/foamy-kit/tools/build-native.sh . --verify  # clean rebuild, byte-identical
```

The animated sky's shaders are compiled: after changing `shaders/*.frag` or
`*.vert`, run `scripts/build-atmosphere.sh` (needs Qt's `qsb`) and commit the
`.qsb` files.

The tests (Python 3, Node, `openssl` and qemu-user for AArch64; development
only) run the helper as a process, `bin/<arch>/foamy-weather-helper` or the
JSON argv prefix in `FOAMY_HELPER`, against a loopback HTTPS stand-in for MET
Norway, Nominatim and Open-Meteo with a throwaway CA (`tests/fakenet.py`; the
helper's test-only `FOAMY_WEATHER_TEST_CONNECT` and `SSL_CERT_FILE`). Nothing
is sent to the real services, and all files go to temporary HOME/XDG
directories.

```sh
for t in tests/*.test.js tests/i18n.test.cjs; do node "$t"; done
python3 -m unittest tests.test_clipboard tests.test_location_privacy
bash tests/test-weather-location.sh
FOAMY_HELPER="[\"$PWD/bin/aarch64/foamy-weather-helper\"]" node tests/weather-fetch.test.js   # and the two above
bash tests/kit-check.sh
python3 tests/i18n-runtime.py                  # live language switching (OMARCHY_PATH picks another tree)
python3 tests/runtime.py                       # needs foamy-kit (FOAMY_KIT)
python3 tests/sky-gpu.py                       # the sky on a GPU (eglfs on a render node); skips without one
```

The offscreen tests run on Omarchy 4.5, the installed `/usr/share/omarchy/shell`
(`FOAMY_HOST_45` picks another 4.5 tree). `tests/runtime.py` also runs on 4.0
when `FOAMY_HOST_40` names a 4.0 shell tree; otherwise it prints a SKIP line
for it.

`preview/Preview.qml` renders mock states with the foamy-kit preview harness
(`FOAMY_HOST_45=/usr/share/omarchy/shell <foamy-kit>/preview/render.py . --host 4.5`).
