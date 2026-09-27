# End-to-end testing

All E2E entry points use `tests/e2e/tailscale_e2e.py`. The shared API is
intentionally close to Playwright:

```python
with TailscaleE2E() as test:
    test.page.expect(lambda state: state.get("backendState") == "Running")
    test.page.tap(1121, 321)
    test.page.screenshot("refresh", "Refresh status")
```

`StatusPage` runs `waf-status.sh` against an isolated `tailscale` stub and
checks `running`, `backendState`, and `error`. `KindlePage` adds real device
taps, waits, and framebuffer screenshots. `KindleE2E` opens the WAF and keeps
the screen awake. It does not tap Start or Stop.

## Commands

```sh
just test  # Rust unit tests and the host E2E scenarios
just e2e   # WAF, status.json, and JSON escape; no Kindle
just demo  # host tests, Kindle tour, and media rendering
```

`just e2e` covers the stopped, connected, login, logged-out, and starting
screens, the Refresh/Start/Stop commands, escaped errors, a missing-binary
status, a failed start log, and a pretty-printed `BackendState`.

## Demo recording

`just demo` needs SSH alias `kindle` (override with `KINDLE_E2E_HOST`), the
Kindle already connected to the tailnet, ffmpeg, and Pillow. The tour:

- opens the WAF and waits until the connection card is on screen. If
  Mesquite leaves its Application Error dialog up, the tour taps CLOSE
  and waits for the card. A frame is kept only when that card and the
  black Connected badge are visible;
- requires `backendState` `Running` before accepting a frame;
- taps Refresh at framebuffer pixel `(1121, 321)` and requires a newer
  `status.json`;
- does not tap Start or Stop, because Stop would drop the tailnet session
  that drives the device.

Raw frames and `frames.json` go to `target/demo/`. `tools/demo_build.py` renders
the MP4, GIF, wide MP4, and poster under `dist/demo/`, and copies the GIF to
`docs/tailscale-demo.gif`.

Touch coordinates are framebuffer pixels for the Oasis 1264×1680 layout. If the
WAF layout changes, measure the Refresh button again before changing
`REFRESH` in `tests/e2e/tailscale_e2e.py`.
