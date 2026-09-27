#!/usr/bin/env python3
"""The single Tailscale end-to-end entry point.

Shaped like a small Playwright API. Host scenarios talk to a status fixture
rather than the Kindle. The recorded tour uses the same page vocabulary for
real taps and framebuffer screenshots:

    with TailscaleE2E() as test:
        test.page.expect(lambda state: state.get("backendState") == "Running",
                         "Kindle is not connected")
        test.page.tap(1121, 321)
        test.page.screenshot("refresh", "Refresh status")

``just e2e`` runs the WAF, status.json, and JSON-escape checks. No Kindle.
``just demo`` adds the Kindle tour and renders its video and animation.
The tour never taps Start or Stop: Stop would drop the tailnet session that
drives the device.
"""
import argparse
import importlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.modules.setdefault("tailscale_e2e", sys.modules[__name__])

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

STATUS_SCRIPT = ROOT / "kpm/tailscale/scripts/waf-status.sh"
# Refresh, measured on a 1264x1680 Oasis framebuffer while the connection
# card is visible. The tour does not press Start or Stop.
REFRESH = (1121, 321)


class Expect:
    def __init__(self, page):
        self.page = page

    def to_have(self, predicate, message="state did not match", timeout=15):
        return self.page.expect(predicate, message, timeout)

    def backend(self, value, timeout=15):
        return self.to_have(lambda state: state.get("backendState") == value,
                            "backendState never became {!r}".format(value), timeout)


class Artifacts:
    """Screenshots plus a storyboard suitable for GIF/MP4 rendering."""

    def __init__(self, directory=None):
        self.directory = Path(directory or ROOT / "target/e2e/artifacts")
        self.frames = []

    def screenshot(self, label, png, caption=None, dwell_ms=1000, **extra):
        self.directory.mkdir(parents=True, exist_ok=True)
        filename = label if str(label).endswith(".png") else label + ".png"
        path = self.directory / filename
        path.write_bytes(png)
        frame = {"label": label, "file": filename, "caption": caption or label,
                 "dwell_ms": dwell_ms}
        frame.update(extra)
        self.frames.append(frame)
        return path

    def animation(self, path=None):
        path = Path(path or self.directory / "animation.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"app": "tailscale", "frames": self.frames}, indent=2) + "\n")
        return path


class StatusPage:
    """One run of waf-status.sh against an isolated tailscale stub."""

    def __init__(self, root):
        self.root = Path(root)
        self.bin = self.root / "bin"
        self.var = self.root / "var"
        self.out = self.root / "status.json"
        self.bin.mkdir()
        self.var.mkdir()
        self.expectation = Expect(self)

    def install_tailscale(self, body):
        path = self.bin / "tailscale"
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        (self.bin / "tailscaled").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "tailscaled").chmod(path.stat().st_mode)

    def start_log(self, text):
        (self.var / "start_log.txt").write_text(text)

    def snapshot(self):
        env = os.environ.copy()
        env.update({"TS_E2E_BIN": str(self.bin), "TS_E2E_VAR": str(self.var),
                    "TS_E2E_STATUS": str(self.out)})
        subprocess.run(["sh", str(STATUS_SCRIPT)], check=True, env=env)
        return json.loads(self.out.read_text())

    def text(self, state):
        return "{} {}".format(state.get("backendState", ""), state.get("error", ""))

    def expect(self, predicate, message="state did not match", timeout=5):
        state = self.snapshot()
        if predicate(state):
            return state
        raise AssertionError("{}: {}".format(message, state))


class KindlePage:
    """Taps and framebuffer captures for the physical WAF."""

    def __init__(self, device, artifacts=None):
        self.device = device
        self.artifacts = artifacts or Artifacts(ROOT / "target/demo/frames")
        self.expectation = Expect(self)

    def prevent_sleep(self, on=True):
        self.device.prevent_sleep(on)

    def launch(self):
        return self.device.launch()

    def tap(self, x, y, pause=500):
        self.device.tap(x, y, pause)

    def snapshot(self):
        return self.device.status()

    def text(self, state):
        return "{} {}".format(state.get("backendState", ""), state.get("error", ""))

    def expect(self, predicate, message="state did not match", timeout=30):
        return self.device.wait(message, predicate, timeout=timeout)

    def screenshot(self, label, caption=None, settle=2.5, **extra):
        time.sleep(settle)
        png = self.device.screenshot()
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("framebuffer capture is not a PNG")
        if not self.device.waf_clean(png):
            debug = self.artifacts.directory.parent / "debug"
            debug.mkdir(parents=True, exist_ok=True)
            (debug / (label + ".png")).write_bytes(png)
            raise RuntimeError("refusing {} because the Tailscale screen is not showing".format(label))
        return self.artifacts.screenshot(label, png, caption, **extra)


class KindleE2E:
    """Opens the WAF and keeps the screen awake. Does not stop tailscaled."""

    def __init__(self):
        from kindle_lib import Device
        self.device = Device()
        self.page = KindlePage(self.device)

    def __enter__(self):
        self.page.prevent_sleep(True)
        return self

    def __exit__(self, *unused):
        self.page.prevent_sleep(False)


def scenario(name, fn):
    print("\n== {} ==".format(name), flush=True)
    fn()


def _page(root, program):
    page = StatusPage(root)
    page.install_tailscale("#!/bin/sh\n" + program + "\n")
    return page


def status_suite():
    with tempfile.TemporaryDirectory(prefix="tailscale-e2e-") as root:
        page = _page(root, """
if [ "$1" = status ] && [ "$2" = --json ]; then
  printf '%s\\n' '{
  "BackendState": "Running"
}'
fi
""")
        state = page.snapshot()
        assert state["running"] is True and state["backendState"] == "Running", state
        assert state["error"] == "" and state["updatedAt"] > 0, state

    with tempfile.TemporaryDirectory(prefix="tailscale-e2e-") as root:
        page = _page(root, "exit 0")
        state = page.snapshot()
        assert state["running"] is False and state["backendState"] == "Stopped", state
        assert state["error"] == "", state
        page.start_log('connect failed: bad "key"\n')
        state = page.snapshot()
        assert state["backendState"] == "Start failed", state
        assert 'bad "key"' in state["error"], state

    with tempfile.TemporaryDirectory(prefix="tailscale-e2e-") as root:
        page = StatusPage(root)
        state = page.snapshot()
        assert state["running"] is False and state["backendState"] == "Binaries missing", state
        assert "reinstall" in state["error"], state

    with tempfile.TemporaryDirectory(prefix="tailscale-e2e-") as root:
        page = _page(root, """
if [ "$1" = status ]; then printf '%s\\n' '{"BackendState":   "NeedsLogin"}'; fi
""")
        state = page.snapshot()
        assert state["running"] is True and state["backendState"] == "NeedsLogin", state


def host_suite():
    scenario("WAF status and controls", lambda: subprocess.run(
        ["node", str(HERE / "waf_e2e.js")], cwd=ROOT, check=True))
    scenario("JSON string escape", lambda: subprocess.run(
        ["sh", str(ROOT / "tests/json_escape_test.sh")], cwd=ROOT, check=True))
    scenario("status.json fixtures", status_suite)


def demo_suite():
    demo = importlib.import_module("kindle_demo")
    builder = importlib.import_module("demo_build")
    saved = sys.argv[:]
    try:
        sys.argv = ["kindle_demo.py"]
        scenario("Kindle WAF tour", demo.main)
        sys.argv = ["demo_build.py"]
        scenario("demo video and animation", builder.main)
    finally:
        sys.argv = saved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true",
                        help="record the WAF tour and encode GIF/MP4")
    args = parser.parse_args()
    host_suite()
    if args.record:
        demo_suite()
    print("\nTailscale E2E: all selected scenarios passed", flush=True)


if __name__ == "__main__":
    main()
