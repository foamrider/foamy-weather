"""The sky on a real GPU (headless: eglfs on a DRM render node), on the 4.5
host via the foamy-kit harness. Skipped when there is no render node or no
eglfs platform plugin; the offscreen software renderer cannot draw the sky.

Regression: the sky must keep its cloud structure when it lands in another
window (Quickshell replaces a layer-shell popup's window across close and
open). A one-shot (live: false) copy of the noise texture came back empty
there, leaving a smooth gradient with no clouds; the reduced-motion still
frame was lost the same way.

  python3 tests/sky-gpu.py

"Cloud structure" is the high-pass texture of the band (pixels minus a 9 px
box blur): about 1.7 with the noise, about 0.7 (dither only) without.
"""
import glob
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402

SHELL = r'''
import QtQuick
import Quickshell
ShellRoot {
  id: shell
  property int step: 0
  property var win: null
  property Item holder: null
  property Item sky: null
  function makeWindow() { return Qt.createQmlObject('import Quickshell; FloatingWindow { implicitWidth: 560; implicitHeight: 230; color: "#1e1e2e" }', shell) }
  function grab(name) { sky.grabToImage(function(r) { r.saveToFile("%OUT%/" + name + ".png"); console.log("GRAB " + name) }) }
  Component.onCompleted: {
    win = makeWindow()
    holder = Qt.createQmlObject('import QtQuick; Item { width: 560; height: 230 }', shell)
    holder.parent = win.contentItem
    sky = Qt.createQmlObject('import QtQuick; import "plugin" as W; W.WeatherBackground { width: 560; height: 230; shown: true; animate: %ANIMATE%;'
      + ' current: ({ symbol: "cloudy", windSpeed: 1.4, cloudCover: 100 }); now: new Date(2026, 10, 1, 11, 59, 0); location: ({ latitude: 59.75, longitude: 10.0 }) }', holder)
  }
  Timer {
    interval: 1200; repeat: true; running: true
    onTriggered: {
      switch (shell.step++) {
      case 0: shell.grab("start"); break
      // One window at a time (eglfs): leave the first, then a new one.
      case 1: shell.holder.parent = null; shell.win.destroy(); break
      case 2: shell.win = shell.makeWindow(); shell.holder.parent = shell.win.contentItem; break
      case 3: shell.grab("moved"); break
      default: console.log(shell.sky.supported ? "FOAMY DONE" : "FOAMY FAIL no GPU renderer"); Qt.quit()
      }
    }
  }
}
'''


def texture(path):
    from PIL import Image, ImageFilter
    import numpy as np
    image = Image.open(path).convert("L")
    a = np.asarray(image, dtype=float)
    b = np.asarray(image.filter(ImageFilter.BoxBlur(9)), dtype=float)
    return float((a - b)[10:150, 10:-10].std())


def main():
    nodes = sorted(glob.glob("/dev/dri/renderD*"))
    eglfs = any(Path(p, "platforms/libqeglfs.so").exists() for p in ("/usr/lib/qt6/plugins", "/usr/lib64/qt6/plugins"))
    if not nodes or not eglfs:
        print("sky-gpu: skipped (no DRM render node or eglfs plugin)")
        return 0
    try:
        import numpy  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError:
        print("sky-gpu: skipped (needs numpy and Pillow)")
        return 0
    status = 0
    for animate in ("true", "false"):
        run = harness.Run("4.5", SHELL, plugin=ROOT, prefix="foamy-weather-sky-gpu-")
        shots = run.base / "shots"
        shots.mkdir()
        run.root.joinpath("shell.qml").write_text(SHELL.replace("%OUT%", str(shots)).replace("%ANIMATE%", animate))
        kms = run.base / "kms.json"
        kms.write_text('{ "device": "%s", "headless": "1920x1080", "hwcursor": false }' % nodes[0])
        run.env.update({"QT_QPA_PLATFORM": "eglfs", "QT_QPA_EGLFS_INTEGRATION": "eglfs_kms", "QT_QPA_EGLFS_KMS_CONFIG": str(kms),
                        "QT_QPA_EGLFS_PHYSICAL_WIDTH": "508", "QT_QPA_EGLFS_PHYSICAL_HEIGHT": "286"})
        run.env.pop("QT_QUICK_BACKEND", None)
        run.run(timeout=60)
        mode = "animated" if animate == "true" else "still (reduced motion)"
        if not run.ok or not (shots / "moved.png").exists():
            print(f"sky-gpu {mode}: FAILED (log {run.base}/qs.log)")
            print("\n".join(run.failures() or run.log.splitlines()[-20:]))
            status = 1
            continue
        start, moved = texture(shots / "start.png"), texture(shots / "moved.png")
        ok = start >= 1.2 and moved >= max(1.2, 0.75 * start)
        print(f"sky-gpu {mode}: cloud texture {start:.2f} -> {moved:.2f} in a new window: {'ok' if ok else 'LOST'}")
        if ok:
            run.cleanup()
        else:
            status = 1
            print(f"  shots in {shots}")
    return status


if __name__ == "__main__":
    sys.exit(main())
