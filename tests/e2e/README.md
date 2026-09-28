# End-to-end tests

`tests/e2e/tailscale_e2e.py` is the sole end-to-end entry point. `StatusPage`
runs the on-device `waf-status.sh` against a temporary `tailscale` stub.
`KindlePage` adds real taps, waits, and framebuffer screenshots. `Artifacts`
writes PNG checkpoints and a storyboard. `KindleE2E` opens the WAF and inhibits
sleep; it never stops `tailscaled`.

`just e2e` needs Node, Python 3, and a POSIX shell. No Kindle is needed.
`waf_e2e.js` checks Stopped, Unavailable (with an escaped error), Connected,
Login required, Logged out, and Starting. Opening the app and tapping Refresh
only run `waf-status.sh`. Start and Stop send `start.sh` and `stop.sh`.
`json_escape_test.sh` checks the status encoder. The status fixtures check a
running daemon, a quiet stop, a failed start log, missing binaries, and a
pretty-printed `BackendState`.

`just test` runs the Rust library tests and then `just e2e`.

`just demo` runs that host suite, then the tour against `ssh kindle`.
Override the alias with `KINDLE_E2E_HOST`. The Kindle must already be
connected. The tour launches through the Library shell integration, fails if an
Application Error dialog appears, and captures a frame only when the
connection card and the Connected badge are visible. It then taps Refresh
and checks that `status.json` was rewritten. Start and Stop are visible on
that screen and are covered by the host WAF test; the tour does not press
them.

Every checkpoint is a Kindle framebuffer PNG. `tools/demo_build.py` renders
`dist/demo/tailscale-demo.mp4`, the GIF, the wide MP4, and a poster, and
copies the GIF to `docs/tailscale-demo.gif`. Tap coordinates are framebuffer
pixels measured on the Oasis. Re-measure `REFRESH` after a layout change.
Read [docs/e2e.md](../../docs/e2e.md) before adding a scenario.
