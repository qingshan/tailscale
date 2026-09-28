#!/usr/bin/env python3
"""Device plumbing for the Kindle tour.

The WAF polls /var/local/mesquite/tailscale/status.json. LIPC runCMD cannot
press a button, so taps go through tools/kindle_xinput.c, which injects
XTEST events the same way the touchscreen does. /usr/sbin/screenshot is the
framebuffer.
"""
import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KINDLE_HOST = os.environ.get("KINDLE_E2E_HOST", "kindle")
STATUS_PATH = "/var/local/mesquite/tailscale/status.json"
XINPUT_REMOTE = "/tmp/kindle_xinput"
XINPUT_BINARY = ROOT / "target/kindlehf-x11/bin/kindle_xinput"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
               "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]


def run(args, **kw):
    kw.setdefault("text", True)
    kw.setdefault("check", True)
    kw.setdefault("timeout", 60)
    kw.setdefault("stdout", subprocess.PIPE)
    return subprocess.run(args, **kw)


def ssh(host, command, **kw):
    return run(["ssh"] + SSH_OPTIONS + [host, command], **kw)


class Device:
    """The Kindle under test: status.json, framebuffer captures, and taps."""

    def __init__(self, host=KINDLE_HOST, status_path=STATUS_PATH):
        self.host = host
        self.status_path = status_path
        self._input_ready = False

    def ssh(self, command, **kw):
        return ssh(self.host, command, **kw)

    def status(self):
        return json.loads(self.ssh("cat " + self.status_path).stdout)

    def prevent_sleep(self, on=True):
        self.ssh("lipc-set-prop com.lab126.powerd preventScreenSaver "
                 + ("1" if on else "0"), check=False)

    def launch(self):
        """Launch through the same shell integration used by Library covers."""
        self.ssh("lipc-set-prop com.lab126.appmgrd start "
                 "app://tech.hackerdude.shell_integration.launcher/mnt/us/documents/tailscale.sh")
        deadline = time.monotonic() + 50
        stable = 0
        while time.monotonic() < deadline:
            active = self.ssh("lipc-get-prop com.lab126.appmgrd activeApp").stdout.strip()
            stable = stable + 1 if active == "dev.qingshan.tailscale" else 0
            if stable >= 4:
                return self.status()
            time.sleep(1)
        raise TimeoutError("Library launch did not leave Tailscale in the foreground")

    def screenshot(self):
        out = self.ssh('f=/tmp/tailscale-shot.png; /usr/sbin/screenshot -f "$f"; cat "$f"',
                       text=False, stdout=subprocess.PIPE).stdout
        if not out.startswith(PNG_MAGIC):
            raise RuntimeError("Kindle framebuffer capture failed")
        return out

    @staticmethod
    def _gray(png):
        import io
        from PIL import Image
        return Image.open(io.BytesIO(png)).convert("L")

    @staticmethod
    def _dark_count(pixels, y, x0, x1, threshold=40):
        return sum(1 for x in range(x0, x1) if pixels[x, y] < threshold)

    @classmethod
    def application_error_visible(cls, png):
        """Mesquite's Application Error dialog: a ~5px rule near y=576.

        The connection card's top border is much thicker and sits higher,
        so this does not match a clean Tailscale screen.
        """
        image = cls._gray(png)
        pixels, width = image.load(), image.size[0]
        hits = 0
        for y in range(570, 590):
            if cls._dark_count(pixels, y, 100, min(width - 100, 1165), 32) > 800:
                hits += 1
        return 3 <= hits <= 10

    @classmethod
    def waf_clean(cls, png):
        """True when the connection card is showing and the error dialog is not.

        The card's top rule is about twenty rows near y=536. The Connected
        badge is the black block just under that rule. A dialog, the
        library, or a page that has not painted yet fails this check.
        """
        if cls.application_error_visible(png):
            return False
        image = cls._gray(png)
        pixels, width = image.load(), image.size[0]
        best = run = 0
        for y in range(520, 565):
            if cls._dark_count(pixels, y, 60, width - 60) > 700:
                run += 1
                if run > best:
                    best = run
            else:
                run = 0
        if best < 12:
            return False
        # Interior of the Connected badge, above the letterforms.
        badge = 0
        total = 0
        for y in range(608, 626):
            for x in range(120, 280):
                total += 1
                if pixels[x, y] < 40:
                    badge += 1
        return badge > total * 0.8

    def foreground(self, timeout=50):
        """Launch from the Library and require a clean connection screen."""
        self.launch()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            image = self.screenshot()
            if self.application_error_visible(image):
                raise RuntimeError("Application Error dialog during Library launch")
            if self.waf_clean(image):
                return image
            time.sleep(1)
        raise TimeoutError("Tailscale WAF did not reach the foreground")

    def ensure_input_tool(self):
        if self._input_ready:
            return
        if not XINPUT_BINARY.exists():
            run([str(ROOT / "tools/build-kindle-xinput.sh")])
        remote = self.ssh("sha1sum {} 2>/dev/null | cut -d' ' -f1".format(XINPUT_REMOTE),
                          check=False).stdout.strip()
        local = run(["sha1sum", str(XINPUT_BINARY)]).stdout.split()[0]
        if remote != local:
            run(["scp", "-q"] + SSH_OPTIONS + [str(XINPUT_BINARY),
                                               "{}:{}".format(self.host, XINPUT_REMOTE)])
            self.ssh("chmod +x " + XINPUT_REMOTE)
        self._input_ready = True

    def gesture(self, commands):
        self.ensure_input_tool()
        out = self.ssh("DISPLAY=:0 {} >/tmp/kindle_xinput.log 2>&1 <<'TS_INPUT'\n{}\nTS_INPUT\n"
                       "echo input_status=$?".format(XINPUT_REMOTE, commands.rstrip()),
                       check=False).stdout
        if "input_status=0" not in out:
            log = self.ssh("cat /tmp/kindle_xinput.log", check=False).stdout
            raise RuntimeError("gesture injection failed:\n{}\n{}".format(out, log))

    def tap(self, x, y, pause=500):
        self.gesture("tap {} {}\nsleep {}".format(int(x), int(y), int(pause)))

    def wait(self, label, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        state = self.status()
        while time.monotonic() < deadline:
            if predicate(state):
                return state
            time.sleep(0.5)
            state = self.status()
        raise TimeoutError("timed out waiting for {}: {}".format(label, state))
