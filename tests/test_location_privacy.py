"""Exercise private coordinate transport and inspect actual procfs command lines."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LATITUDE, LONGITUDE = '12.3456', '-56.7890'
FORECAST = '{"type":"Feature","properties":{"timeseries":[{"time":"2026-10-09T10:00:00Z","data":{}}]}}'
SUN = '{"properties":{"sunrise":{"time":"2026-10-09T06:00:00Z"},"sunset":{"time":"2026-10-09T18:00:00Z"}}}'


class PrivateLocation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='weather-privacy-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.audit = self.base / 'argv'
        self.audit.touch()
        self.urls = self.base / 'urls'
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin',
                        XDG_CACHE_HOME=str(self.base / 'cache'),
                        XDG_CONFIG_HOME=str(self.base / 'config'),
                        WEATHER_LOCATION_RUNTIME_DIR=str(self.base / 'runtime'),
                        WEATHER_GEOCLUE_COMMAND=str(self.bin / 'where-am-i'),
                        WEATHER_PRIVACY_AUDIT=str(self.audit), WEATHER_PRIVACY_URLS=str(self.urls))
        # Sample the actual helper process and its caller before exec forwards argv.
        prefix = '''#!/bin/bash
set -euo pipefail
for pid in "$BASHPID" "$PPID"; do
  if [[ -r /proc/$pid/cmdline ]]; then
    mapfile -d '' -t argv <"/proc/$pid/cmdline"
    printf '%s\\0' "${argv[@]}" >>"$WEATHER_PRIVACY_AUDIT"
  fi
done
'''
        commands = ['awk', 'cat', 'chmod', 'curl', 'date', 'find', 'head', 'jq',
                    'mkdir', 'mktemp', 'mv', 'rm', 'sha256sum', 'stat', 'timeout', 'touch']
        for command in commands:
            target = shutil.which(command, path='/usr/bin')
            self.assertIsNotNone(target)
            if command == 'curl':
                body = '''IFS= read -r config
printf '%s\\n' "$config" >>"$WEATHER_PRIVACY_URLS"
case "$config" in
  *locationforecast*) printf '%s\\n' ''' + repr(FORECAST) + ''' ;;
  *sunrise*) printf '%s\\n' ''' + repr(SUN) + ''' ;;
  *) printf '%s\\n' "${WEATHER_PRIVACY_LABEL_RESPONSE:-{}}" ;;
esac
'''
            else:
                body = 'exec ' + target + ' "$@"\n'
            file = self.bin / command
            file.write_text(prefix + body)
            file.chmod(0o755)
        geoclue = self.bin / 'where-am-i'
        geoclue.write_text('#!/bin/bash\nprintf "%s\\n" "Latitude: ' + LATITUDE +
                           '°" "Longitude: ' + LONGITUDE + '°"\n')
        geoclue.chmod(0o755)

    def run_script(self, name, args=(), payload='', check=True):
        return subprocess.run([str(ROOT / 'scripts' / name), *args], input=payload,
                              text=True, capture_output=True, env=self.env, timeout=15, check=check)

    def assert_private(self):
        argv = self.audit.read_bytes().decode()
        for secret in [LATITUDE, LONGITUDE, '12.35', '-56.79']:
            self.assertNotIn(secret, argv)
        self.assertIn('awk', argv)
        self.assertIn('jq', argv)

    def test_automatic_location_and_forecast_keep_coordinates_out_of_procfs(self):
        # The no-name response forces the coordinate-label fallback through jq too.
        location = json.loads(self.run_script('weather-resolve-location.sh', ['--force']).stdout)
        self.assertEqual(location['latitude'], float(LATITUDE))
        self.assertEqual(location['longitude'], float(LONGITUDE))
        self.assertEqual(location['name'], '12.35, -56.79')
        report = json.loads(self.run_script('weather-fetch.sh', ['--force'],
                                           LATITUDE + '\n' + LONGITUDE + '\n').stdout)
        self.assertFalse(report['stale'])
        self.assertEqual(len(report['sun']), 3)
        self.assertIn('lat=' + LATITUDE + '&lon=' + LONGITUDE, self.urls.read_text())
        self.assert_private()
        for root in [self.base / 'cache/omarchy-weather', self.base / 'runtime']:
            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            for file in root.iterdir():
                self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
                self.assertNotIn(LATITUDE, file.name)
                self.assertNotIn(LONGITUDE, file.name)

    def test_legacy_caches_preserve_data_and_age_without_exposing_paths(self):
        cache = self.base / 'cache/omarchy-weather'
        cache.mkdir(parents=True, mode=0o700)
        label = cache / 'location-12.35_-56.79.json'
        label.write_text('{"name":"Old Town"}')
        old_forecast = cache / ('forecast-complete-' + LATITUDE + '_' + LONGITUDE + '.json')
        old_forecast.write_text(FORECAST)
        old_time = int(time.time()) - 3600
        os.utime(old_forecast, (old_time, old_time))
        location = json.loads(self.run_script('weather-resolve-location.sh', ['--force']).stdout)
        self.assertEqual(location['name'], 'Old Town')
        # Failed refreshes must still use the migrated forecast as stale data.
        curl = self.bin / 'curl'
        curl.write_text(curl.read_text().split('IFS= read -r config')[0] + 'exit 22\n')
        report = json.loads(self.run_script('weather-fetch.sh', ['--force'],
                                           LATITUDE + '\n' + LONGITUDE + '\n').stdout)
        self.assertTrue(report['stale'])
        key = hashlib.sha256((LATITUDE + '_' + LONGITUDE).encode()).hexdigest()
        migrated = cache / ('forecast-complete-' + key + '.json')
        self.assertEqual(migrated.stat().st_mtime, old_time)
        self.assertEqual(json.loads(migrated.read_text()), json.loads(FORECAST))
        self.assert_private()

    def test_manual_location_uses_stdin_and_rejects_invalid_input(self):
        location = {'name': 'Example\nTown', 'latitude': float(LATITUDE), 'longitude': float(LONGITUDE)}
        self.run_script('weather-location.sh', ['--set'], json.dumps(location))
        file = self.base / 'config/omarchy/weather-location.local.json'
        self.assertEqual(json.loads(file.read_text()), location)
        self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
        for payload in ['', '{broken', '{}', json.dumps(dict(location, latitude=91)),
                        json.dumps(location) + '\n' + json.dumps(location)]:
            result = self.run_script('weather-location.sh', ['--set'], payload, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(file.read_text()), location)
        argv = self.audit.read_bytes().decode()
        self.assertNotIn(LATITUDE, argv)
        self.assertNotIn(LONGITUDE, argv)
        self.assertNotIn('Example', argv)

    def test_invalid_forecast_coordinates_do_not_start_a_download(self):
        for payload in ['', '12.3456\n', '91\n0\n', '12;echo exposed\n34\n']:
            report = json.loads(self.run_script('weather-fetch.sh', payload=payload).stdout)
            self.assertIn('error', report)
            self.assertFalse(self.urls.exists())

    def test_quickshell_sends_fresh_stdin_on_repeated_fetch_and_location_save(self):
        qml = (ROOT / 'Panel.qml').read_text()

        def block(marker, start=0):
            begin = qml.index(marker, start)
            end = qml.index('{', begin) + 1
            depth = 1
            while depth:
                depth += (qml[end] == '{') - (qml[end] == '}')
                end += 1
            return qml[begin:end]

        # Use the production launch functions and write handlers, with real helpers.
        weather_started = block('onStarted:', qml.index('id: weatherProc'))
        save_started = block('onStarted:', qml.index('id: locationSaveProc'))
        app = self.base / 'app'
        app.mkdir()
        (app / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property bool networkReady: true
  property bool hasCoordinates: true
  property bool automaticLocation: false
  property bool savingLocation: false
  property bool loading: false
  property string errorMessage: ""
  property string requestUserAgent: ""
  property var now
  property var configuredLocationState: ({latitude:12.3456,longitude:-56.7890})
  property var report: null
  property bool saved: false
  property int step: 0
  property string fetchScript: ''' + json.dumps(str(ROOT / 'scripts/weather-fetch.sh')) + '''
  property string locationScript: ''' + json.dumps(str(ROOT / 'scripts/weather-location.sh')) + '\n' +
            block('function refresh(') + '\n' + block('function pickSuggestion(') + '''
  Process {
    id: weatherProc
    property string requestInput: ""
    ''' + weather_started + '''
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.report = JSON.parse(text) }
  }
  Process {
    id: locationSaveProc
    property string requestInput: ""
    ''' + save_started + '''
    onExited: function(code) { if (code !== 0) throw new Error("save failed"); root.saved = true }
  }
  Timer {
    interval: 30; repeat: true; running: true
    onTriggered: {
      if (root.step === 0) { root.refresh(false); root.step = 1 }
      else if (root.step < 3 && !weatherProc.running && root.report) {
        if (root.report.error || root.report.sun.length !== 3) throw new Error("fetch failed")
        if (root.step === 1) {
          root.configuredLocationState = {latitude:8.7654,longitude:9.8765}
          root.report = null; root.refresh(true); root.step = 2
        } else {
          root.pickSuggestion({name:"Pipe Town",latitude:8.7654,longitude:9.8765}); root.step = 3
        }
      } else if (root.step === 3 && root.saved) { console.log("PRIVATE PIPE PASS"); Qt.quit() }
    }
  }
  Timer { interval: 10000; running: true; onTriggered: { console.log("PRIVATE PIPE TIMEOUT"); Qt.quit() } }
}
''')
        runtime = self.base / 'qt-runtime'
        runtime.mkdir(mode=0o700)
        env = dict(self.env, XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen',
                   QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='')
        for key in ['DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE']:
            env.pop(key, None)
        result = subprocess.run(['dbus-run-session', '--', '/usr/bin/qs', '-p', str(app), '--no-color'],
                                env=env, text=True, capture_output=True, timeout=15, check=True)
        self.assertIn('PRIVATE PIPE PASS', result.stdout + result.stderr)
        self.assertIn('lat=8.7654&lon=9.8765', self.urls.read_text())
        saved = json.loads((self.base / 'config/omarchy/weather-location.local.json').read_text())
        self.assertEqual(saved, {'name': 'Pipe Town', 'latitude': 8.7654, 'longitude': 9.8765})
        self.assert_private()
        argv = self.audit.read_text()
        self.assertNotIn('8.7654', argv)
        self.assertNotIn('9.8765', argv)


if __name__ == '__main__':
    unittest.main()
