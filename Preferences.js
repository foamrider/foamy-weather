// Widget preferences come from shell.json; forecasts remain in MET's original units.
function fromSettings(value, locale) {
  value = value && typeof value === "object" && !Array.isArray(value) ? value : {}
  var defaultLanguage = /^(nb|nn|no)(_|-|$)/i.test(String(locale || "")) ? "nb" : "en"
  // Keep the selected mode separate so the UI can return to following the system.
  var languageMode = value.language === "nb" || value.language === "en" ? value.language : "system"
  return {
    languageMode: languageMode,
    language: languageMode === "system" ? defaultLanguage : languageMode,
    units: value.units === "imperial" ? "imperial" : "metric",
    automaticLocation: value.automaticLocation === true,
    animations: value.animations !== false
  }
}

var english = {
  "Lett sludd og torden": "Light sleet and thunder",
  "Sludd og torden": "Sleet and thunder",
  "Kraftig sludd og torden": "Heavy sleet and thunder",
  "Innstillinger": "Settings",
  "Tilbake": "Back",
  "Posisjon": "Location",
  "Bruk posisjonsdata": "Use location data",
  "Automatisk via GeoClue. Posisjonen brukes av MET Norway og OpenStreetMap.": "Automatic via GeoClue. Your location is used by MET Norway and OpenStreetMap.",
  "Valgt sted": "Selected location",
  "Søk etter sted": "Search for a location",
  "Søk for å velge et fast sted.": "Search to choose a fixed location.",
  "Ingen treff": "No locations found",
  "Søker…": "Searching…",
  "Finner posisjon…": "Finding location…",
  "Kunne ikke søke etter sted": "Could not search for a location",
  "Kunne ikke lagre innstillingene": "Could not save settings",
  "Kunne ikke lese innstillingene": "Could not read settings",
  "Språk": "Language",
  "Standard (systemspråk)": "Default (system language)",
  "Enheter": "Units",
  "Metrisk (°C, km/t, mm)": "Metric (°C, km/h, mm)",
  "Imperial (°F, mph, in)": "Imperial (°F, mph, in)",
  "Animert bakgrunn": "Animated background",
  "Vis været som en animasjon i toppen.": "Show animated weather in the header.",
  "Velg sted": "Choose location",
  "Velg et sted for å hente værdata": "Choose a location to load weather",
  "Velg et sted fra søkeresultatene": "Choose a location from the search results",
  "Kunne ikke lagre stedet": "Could not save the location",
  "Kunne ikke finne automatisk posisjon": "Could not find automatic location",
  "Kunne ikke lese automatisk posisjon": "Could not read automatic location",
  "Kunne ikke lese værdata": "Could not read weather data",
  "Ugyldig svar fra MET Norway": "Invalid response from MET Norway",
  "Viser sist kjente værdata": "Showing last known weather",
  "Værdata er utilgjengelig": "Weather data is unavailable",
  "Ingen værdata": "No weather data",
  "Henter værdata…": "Loading weather…",
  "Venter på værdata": "Waiting for weather",
  "Nedbør fra kl. ": "Precipitation from ",
  "Opphold i perioden": "No precipitation expected",
  "Lav": "Low",
  "Moderat": "Moderate",
  "Høy": "High",
  "Svært høy": "Very high",
  "Nordlig": "Northerly",
  "Nordøstlig": "Northeasterly",
  "Østlig": "Easterly",
  "Sørøstlig": "Southeasterly",
  "Sørlig": "Southerly",
  "Sørvestlig": "Southwesterly",
  "Vestlig": "Westerly",
  "Nordvestlig": "Northwesterly",
  "Vind": "Wind",
  "Fuktighet": "Humidity",
  "Luftfuktighet": "Humidity",
  "Neste time": "Next hour",
  "Relativ": "Relative",
  "Nedbør": "Precipitation",
  "UV-indeks": "UV index",
  "Tre dagers varsel": "Three-day forecast",
  "Time for time": "Hourly forecast",
  "I dag": "Today",
  "I morgen": "Tomorrow",
  "Høy ": "High ",
  " · Lav ": " · Low ",
  "Oppdatert ": "Updated ",
  "Oppdater": "Refresh",
  "Oppdaterer…": "Refreshing…",
  "Venter på nettverk…": "Waiting for network…",
  "Været i ": "Weather in ",
  "valgt sted": "selected location",
  "Klart": "Clear",
  "Lettskyet": "Mostly clear",
  "Delvis skyet": "Partly cloudy",
  "Skyet": "Cloudy",
  "Tåke": "Fog",
  "Lett regn": "Light rain",
  "Lette regnbyger": "Light rain showers",
  "Regn": "Rain",
  "Regnbyger": "Rain showers",
  "Kraftig regn": "Heavy rain",
  "Kraftige regnbyger": "Heavy rain showers",
  "Lett tordenvær": "Light thunderstorms",
  "Tordenvær": "Thunderstorms",
  "Kraftig tordenvær": "Heavy thunderstorms",
  "Lett sludd": "Light sleet",
  "Sludd": "Sleet",
  "Kraftig sludd": "Heavy sleet",
  "Lett snø": "Light snow",
  "Snø": "Snow",
  "Kraftig snø": "Heavy snow",
  "Lett snø og torden": "Light snow and thunder",
  "Snø og torden": "Snow and thunder",
  "Kraftig snø og torden": "Heavy snow and thunder"
}

function text(value, language) {
  return language === "en" ? (english[value] || value) : value
}

function temperature(value, units) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return Math.round(units === "imperial" ? Number(value) * 9 / 5 + 32 : Number(value)) + "°"
}

function precipitation(value, units) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  var imperial = units === "imperial"
  var number = Number(value) / (imperial ? 25.4 : 1)
  return String(Number(number.toFixed(imperial ? 2 : 1))) + (imperial ? " in" : " mm")
}

function wind(value, units, language) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return Math.round(Number(value) * (units === "imperial" ? 2.236936 : 3.6))
    + (units === "imperial" ? " mph" : language === "en" ? " km/h" : " km/t")
}

function age(value, now, language) {
  var date = new Date(value)
  if (isNaN(date.getTime())) return ""
  var minutes = Math.max(0, Math.round((now.getTime() - date.getTime()) / 60000))
  if (minutes < 2) return language === "en" ? "now" : "nå"
  if (minutes < 60) return minutes + (language === "en" ? " min ago" : " min siden")
  var hours = Math.floor(minutes / 60)
  return hours + (language === "en" ? " h ago" : hours === 1 ? " time siden" : " timer siden")
}

if (typeof module !== "undefined") module.exports = { fromSettings, text, temperature, precipitation, wind, age }
