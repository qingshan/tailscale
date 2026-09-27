#!/usr/bin/env python3
"""Record the Tailscale tour from a real Kindle.

The device must already be on the tailnet. The tour opens the WAF, checks
status.json, taps Refresh, and captures the framebuffer. It does not tap
Start or Stop: Stop would drop the tailnet SSH session used to drive the
Kindle.

    python3 tests/e2e/kindle_demo.py
"""
import json
import time

from tailscale_e2e import REFRESH, ROOT, KindleE2E

FRAMES = ROOT / "target/demo/frames"
STORYBOARD = ROOT / "target/demo/frames.json"


def card(label, subtitle, lines, footer, headline, detail, dwell=3200):
    return {"label": label, "kind": "card", "dwell_ms": dwell, "subtitle": subtitle,
            "lines": lines, "footer": footer, "headline": headline, "detail": detail,
            "caption": subtitle}


def main():
    frames = [card(
        "01-title",
        "Connect a Kindle to your tailnet",
        ["Status, start, and stop on the Kindle",
         "Tailscale SSH in from another machine",
         "Kindle Oasis, kindlehf"],
        "captured on a real Kindle",
        "tailscale",
        "An unofficial Kindle control screen for the official Tailscale binaries.")]
    with KindleE2E() as test:
        test.device.foreground()
        state = test.page.expect(
            lambda item: item.get("running") is True and item.get("backendState") == "Running",
            "tour records the connected screen and will not press Start or Stop")
        seen = state.get("updatedAt", 0)
        test.page.screenshot("02-connected", "Connected to your tailnet", dwell_ms=3400,
                             detail="The page polls status.json. Opening it does not start Tailscale.")
        frames.append(test.page.artifacts.frames[-1])
        while time.time() <= seen:
            time.sleep(0.2)
        test.page.tap(*REFRESH)
        test.page.expect(lambda item: item.get("backendState") == "Running"
                         and item.get("updatedAt", 0) > seen,
                         "Refresh did not rewrite status.json")
        test.page.screenshot("03-refresh", "Refresh status on the Kindle", dwell_ms=3000,
                             detail="Refresh asks tsctl to rewrite status.json. Start and Stop stay put.")
        frames.append(test.page.artifacts.frames[-1])
    frames.append(card(
        "04-ssh",
        "SSH in from another machine",
        ["tailscale ssh root@kindle",
         "The shell is root",
         "Your tailnet SSH rules still apply"],
        "no OpenSSH client on the Kindle",
        "Tailscale SSH",
        "tailscaled accepts the session. The package does not install sshd."))
    STORYBOARD.parent.mkdir(parents=True, exist_ok=True)
    STORYBOARD.write_text(json.dumps({"app": "tailscale", "frames": frames}, indent=2) + "\n")
    print("captured", sum(1 for frame in frames if frame.get("file")), "frames in", FRAMES)


if __name__ == "__main__":
    main()
