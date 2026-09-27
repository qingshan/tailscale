# Agent notes

Standalone **kpm** package for a jailbroken Kindle Oasis 10th gen (`kindlehf`,
firmware 5.16.x “juno”, Mesquite WAF): Tailscale via `tsctl`. Inbound
shell access is Tailscale SSH (`--ssh` in `up.args`), not a local OpenSSH
client.

## Commands

```sh
just test                              # cargo test --lib, then host e2e
just e2e                               # WAF, status.json, JSON escape; no Kindle
just demo                              # host e2e, Kindle tour, MP4/GIF
just demo-build                        # re-encode target/demo/frames
just package                           # cross-compile kindlehf + pack .kpkg into dist/
just package <x.y.z>                   # bump kpm package version while packing
just package <x.y.z> <tailscale_ver>   # also pin the install-time Tailscale release
just toolchain                         # once: ~/x-tools kindlehf gcc + liblipc stub
just publish                           # publish an existing release URL to the KPM catalog (KINDLE_CATALOG_TOKEN)
```

`tests/e2e/tailscale_e2e.py` is the only E2E entry point. Host scenarios use
`StatusPage` against a stub `tailscale`. The Kindle tour uses `KindlePage`
taps and framebuffer screenshots. It must not tap Start or Stop: Stop drops
the tailnet SSH session. `REFRESH` is a framebuffer pixel; re-measure it
after a WAF layout change. See [docs/e2e.md](docs/e2e.md).

Kindle crates **cannot be linked natively** (`liblipc`). Use
`cargo test -p tailscale --lib`; do not build `tsctl` on the host.

`.kpkg` files under `dist/` are build output.

## Version bumps

KPM only reinstalls when the version changes. After daemon, WAF, or script
edits, bump **all** of:

- `kpm/manifest.json`
- `crates/tailscale/Cargo.toml`
- `kpm/waf/index.html` `?v=` on `style.css` and `script.js`

`just package <x.y.z>` rewrites the kpm bits; still bump the crate version.
The install-time Tailscale release is `kpm/tailscale/version` (override with
the second `just package` argument).

## Package shape

Rust LIPC runner + Mesquite WAF. Official `tailscale`/`tailscaled` binaries
are downloaded on-device at install time, not bundled.

| Daemon / LIPC | On-device |
| --- | --- |
| `tsctl` `dev.qingshan.tsctl` | `/mnt/us/tailscale` |

Shared Kindle helpers: [`common/`](common/) (`pkg-lib.sh`, `waf-base.js/css`).
Install scripts are POSIX `sh` (Kindle ash). `KEEP_ON_UPGRADE` (`bin/` and
`var/`) survives reinstall — do not wipe the auth key or node state.

WAF sends one-way shell strings on the LIPC `runCMD` property
(`sendStringCmd`) and **polls** `status.json` written by `waf-status.sh`
in `/var/local/mesquite/tailscale/`. No fetch, no sync LIPC RPC.

## WAF (Mesquite WebKitGTK 1.0.7.2)

- **JS:** ES5 only — `var`, no `const`/`let`, arrows, template literals,
  Promises, `class`, modules.
- **CSS:** CSS2 — no flexbox, grid, or `position:fixed`.
- Prefer `mousedown` over `click` (this WebKit often never delivers
  mouseup/click). Invert a beat (`PRESS_FLASH_MS`) before navigation so
  e-ink shows the tap.
- One overlay at a time (dropdown / modal / error pop).

## Style

- Rust 2021, `cargo fmt`. Host-testable logic in `crates/tailscale/src/*.rs`
  (`#[cfg(test)]`); keep `src/bin/tsctl.rs` as the LIPC/IO shell.
- Commit subject: imperative, what changed (“Fix tailscale watchdog restart”).
- Comments: short and factual; no changelog narration.
- Do not add a native `cargo build` of Kindle bins to CI-style checks on
  the host.
