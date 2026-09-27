# Tailscale Kindle package (tsctl).

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Host tests only. Do not natively link tsctl (liblipc). Needs Node.
test:
    cargo test -p tailscale --lib
    python3 tests/e2e/tailscale_e2e.py

# WAF, status.json, and JSON-escape scenarios. No Kindle.
e2e:
    python3 tests/e2e/tailscale_e2e.py

# Host tests, then the real-Kindle tour and MP4/GIF rendering.
demo:
    ./tools/build-kindle-xinput.sh
    python3 tests/e2e/tailscale_e2e.py --record

# Re-encode dist/demo from frames already captured (no device needed).
demo-build:
    python3 tools/demo_build.py

# Install kindlehf gcc (~/x-tools) and the liblipc link stub.
toolchain:
    ./tools/setup-toolchain.sh

# Cross-compile tsctl and write a .kpkg to dist/.
# Usage: just package [version] [tailscale_version]
package version="" ts_version="": toolchain
    ./tools/pkg-build.sh {{version}} {{ts_version}}

# Build and publish the package to the shared KPM catalog.
# Requires KINDLE_CATALOG_TOKEN when the catalog remote uses HTTPS.
publish version="" ts_version="": toolchain
    ./tools/publish.sh {{version}} {{ts_version}}
