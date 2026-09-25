# Foamy Weather

Current weather and a three-day forecast.

![Foamy Weather screenshot](screenshot.png)

## Install

For automatic location, install GeoClue (`geoclue`).
Disable another weather widget before enabling this one.

```sh
omarchy plugin add https://github.com/foamrider/foamy-weather.git --enable
```

## Use

1. Left-click the widget and open the settings cog.
2. Search for a location and select a result.
3. Choose language, units, and whether to animate the background.

Left-click opens the forecast, middle-click refreshes, and right-click shows a
summary. Select a day to see its hourly forecast. **Use location data** enables
optional automatic positioning; it is off by default.

## License

Weather: [MET Norway](https://www.met.no/), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Search: [Open-Meteo](https://open-meteo.com/) / GeoNames.
Automatic location names: [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).

Code: [MIT](LICENSE). Third-party notices:
[Omarchy](LICENSE-OMARCHY), [Atmosphere](LICENSE-ATMOSPHERE),
[Meteocons](LICENSE-METEOCONS), and [Lucide](LICENSE-LUCIDE).

Provided **as is**, without warranty or guaranteed support. Use at your own risk.
