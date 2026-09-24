# Foamy Weather

A weather plugin for Omarchy Quattro (plugin ID `foamy.weather`). The MET Norway
panel uses a compact, 600-pixel-wide layout. Its
header animates the current MET condition with clouds, rain, snow, mixed sleet,
fog, and thunder. The selected location and current time determine daylight,
including polar day/night; MET day/night suffixes are the fallback when coordinates
are unavailable. Forecasts are cached locally and remain available during temporary network failures. Cached reports also drive the background.


## Installation

```sh
omarchy plugin add https://github.com/foamrider/foamy-weather.git --enable
```

## Local development

Requires Omarchy Quattro with its Quickshell shell, `bash`, `curl`, `jq`, GNU
coreutils, and `awk`. Automatic positioning additionally uses GeoClue. Node.js
and Qt's `qsb` are only needed for tests and shader development respectively.

From the project directory, link the checkout for development (the destination
must not already exist):

```sh
omarchy plugin validate .
mkdir -p ~/.config/omarchy/plugins
ln -s "$PWD" ~/.config/omarchy/plugins/foamy.weather
omarchy restart shell
omarchy plugin enable foamy.weather
```

Edit this checkout and run `omarchy restart shell` before testing changes. The
installed plugin reads these files directly; no copy or reinstall is needed.

Disable another weather plugin before enabling this one. Open the settings cog
to choose a location. Left-click opens the forecast, middle-click refreshes it,
and right-click shows a notification summary. For keyboard bindings, use
`omarchy-shell foamy.weather toggle` or `omarchy-shell foamy.weather edit`.

## Forecast and settings

The hourly forecast shows all eight available three-hour slots, including 18:00
and 21:00 for full days. Today rolls forward from the current hour across midnight.
The slots share one row at normal width and wrap to two rows on narrow screens.

The top-right settings cog replaces the area below the animated header with
settings. Enter also opens settings; Escape or Back returns to the forecast.
Opening settings neither focuses the search field nor starts a location search.
Typing at least two characters searches Open-Meteo, and selecting a result saves
a fixed location.

Settings include Norwegian Bokmål/English, metric (°C, km/h, mm) or imperial
(°F, mph, inches), and animated backgrounds. Units apply to the header, bar,
daily/hourly forecasts, wind, precipitation, and notification summary. Forecast
calculations keep MET's original units. New installations use Norwegian for a
Norwegian system locale and English otherwise, with metric units and animations
enabled. “Default (system language)” follows the system locale, falling back to
English for unsupported languages. Choosing Norwegian or English overrides it.

Automatic positioning is off by default. Enabling “Use location data” uses
GeoClue, reverse-geocodes through OpenStreetMap Nominatim, and requests weather
from MET Norway. Disabling it stops location lookup and restores the saved fixed
location.
A failed lookup is shown in settings, where users can return to a fixed location.

Preferences are stored directly on this widget's entry in
`$XDG_CONFIG_HOME/omarchy/shell.json` (falling back to `~/.config`). The settings
controls call `omarchy bar set <installed-plugin-id> <key> <value> --json`, allowing
the shell to update its live state and persist the change. The installed ID is
read from `manifest.json`, so publishing under another namespace does not require
changing the persistence code. The supported keys are `language` (`system`, `nb`, or `en`; defaults to `system`),
`units` (`metric` or `imperial`), `automaticLocation`, and `animations`.
`refreshMinutes` and `locationRefreshMinutes` remain optional widget settings
(30 and 15 minutes by default).

The selected fixed location remains in `weather-location.local.json`, outside
the plugin, matching Omarchy's separation of user configuration and location
state. The built-in location state also respects `XDG_STATE_HOME`. GeoClue data
and forecast caches stay in the user's runtime/cache directories. No location is
configured by default.

The provider User-Agent defaults to
`foamy-weather/1.1.0 (+https://github.com/foamrider/foamy-weather)`, identifying the project and
its maintainer. The contact URL lets API operators reach the maintainer; it is
not an API key or callback. Forks should identify their own application and maintainer.

The widget's optional `requestUserAgent` setting overrides this value. Direct
script callers can use `MET_WEATHER_USER_AGENT` and `WEATHER_LOCATION_USER_AGENT`.
See [MET's identification requirements](https://api.met.no/doc/TermsOfService)
and [Nominatim's usage policy](https://operations.osmfoundation.org/policies/nominatim/).

`WeatherBackground.qml` renders at native display resolution (including HiDPI
scaling) and 20 updates per second,
with a light blur, translucent theme overlay, and a soft shadow behind header
text and icons. Motion stops when the popup is closed or the
header is scrolled away. Missing/unknown weather or shader errors retain the
static theme background. Forecast-day selection does not change the current-weather
header. `WeatherScene.js` maps MET symbols and hourly precipitation to the scene.

The shader and noise texture are adapted from [Atmosphere](https://github.com/takustaqu/atmosphere)
revision `0b6d169a03f0be533b752c13a626fff2bf7bde56` (`src/renderer.ts`,
`src/noise.ts`, and the solar calculation in `src/sun.ts`). `LICENSE-ATMOSPHERE`
retains its MIT license. The Qt port uses a uniform block, item-local texture
coordinates, explicit-LOD noise sampling, renamed GLSL reserved identifiers, and
SDR/sRGB output. `shaders/noise.png` is the upstream 256 × 256 float32 noise lattice.
All assets are bundled locally; no browser, package install, or runtime download
is needed. After changing the shader, rebuild the bundled Qt shader with:

```sh
bash scripts/build-atmosphere.sh
node tests/weather-scene.test.js
node tests/model.test.js
node tests/preferences.test.js
node tests/weather-icons.test.js
bash tests/test-weather-location.sh
omarchy plugin validate .
```

`WeatherPopup.qml` is an adapted copy of Omarchy Quattro's `Ui/KeyboardPanel.qml`.
Its only changes are importing `qs.Ui` and exposing the card radius and surface
color. When updating Omarchy, compare this file with the packaged original and
carry over focus, geometry, dismissal, and popup-coordination fixes.

The location input and language/unit controls use a 7-pixel corner radius.
`WeatherDropdown.qml` adapts Omarchy's `Ui/Dropdown.qml` to apply that radius to
the trigger, menu, and option highlights while retaining its keyboard and focus
behavior. Compare it with the packaged original when updating Omarchy; its
upstream notice is retained in `LICENSE-OMARCHY`.

`WeatherConditionIcon.qml` uses the bundled colorful Fill SVGs from
[Meteocons](https://github.com/basmilius/meteocons), `@meteocons/svg-static` 0.1.0.
The unmodified files in `icons/` and `LICENSE-METEOCONS` come from that release's
`fill/` directory and MIT license. `WeatherIcons.js` maps MET conditions to these
assets, including day/night, polar twilight, showers, and mixed precipitation.
The header, daily cards, and hourly forecast share the same mapping. These static
SVGs add no animation timers or runtime downloads.

`WeatherIcons.js` also contains the theme-colored Lucide paths for controls and
metrics, covered by `LICENSE-LUCIDE`. Check the condition mapping and bundled
assets with `node tests/weather-icons.test.js`.

## License and data attribution

Plugin code is available under the [MIT license](LICENSE). Omarchy-derived code,
including the popup and bar integration, retains the upstream notice in
[LICENSE-OMARCHY](LICENSE-OMARCHY). Bundled assets retain their separate notices in
`LICENSE-ATMOSPHERE`, `LICENSE-METEOCONS`, and `LICENSE-LUCIDE` (MIT/ISC).

Weather data: [MET Norway](https://www.met.no/),
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The plugin summarizes
forecasts and converts displayed units. Location search:
[Open-Meteo](https://open-meteo.com/), using GeoNames data. Automatic location
names: [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
via Nominatim. Location queries are sent directly to these providers.
