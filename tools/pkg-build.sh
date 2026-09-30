#!/bin/sh
# Cross-compile tsctl for kindlehf and pack a standalone kpm artifact.
#
# Usage: tools/pkg-build.sh [package_version] [tailscale_version]
#   package_version   - kpm package version (defaults to kpm/manifest.json)
#   tailscale_version - Tailscale release fetched at install time
#                       (defaults to kpm/tailscale/version)

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KPM_DIR=$ROOT/kpm
DIST_DIR=$ROOT/dist
TARGET=armv7-unknown-linux-gnueabihf
XTOOLS=${XTOOLS:-$HOME/x-tools/arm-kindlehf-linux-gnueabihf/bin}
PLATFORM=kindlehf
GCC=$XTOOLS/arm-kindlehf-linux-gnueabihf-gcc

if [ ! -x "$GCC" ]; then
    echo "error: kindlehf gcc not found at $GCC" >&2
    echo "Run: just toolchain" >&2
    exit 1
fi

# shellcheck disable=SC1091
. "$KPM_DIR/pkg.env"
EXTRA_BINS=
VERSION_FILE=
if [ -f "$KPM_DIR/pack.env" ]; then
    # shellcheck disable=SC1091
    . "$KPM_DIR/pack.env"
fi

PKG_VERSION=${1:-}
if [ -z "$PKG_VERSION" ]; then
    PKG_VERSION=$(python3 -c "import json; print('.'.join(str(v) for v in json.load(open('$KPM_DIR/manifest.json'))['version']))")
fi

TS_VERSION=${2:-}
if [ -z "$TS_VERSION" ] && [ -n "${VERSION_FILE:-}" ] && [ -f "$KPM_DIR/$VERSION_FILE" ]; then
    TS_VERSION=$(cat "$KPM_DIR/$VERSION_FILE")
fi
if [ -z "$TS_VERSION" ]; then
    TS_VERSION=$PKG_VERSION
fi

export PATH="$XTOOLS:$PATH"
# Cargo otherwise falls back to the host `cc`, which cannot link ARM objects.
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER="$GCC"
# liblipc exists only on the Kindle. setup-toolchain.sh builds this
# SONAME-compatible stub solely for the cross-link step.
LIPC_STUB_DIR=$ROOT/target/kindlehf-sysroot/lib
if [ ! -e "$LIPC_STUB_DIR/liblipc.so" ]; then
    echo "error: liblipc link stub not found at $LIPC_STUB_DIR/liblipc.so" >&2
    echo "Run: just toolchain" >&2
    exit 1
fi
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-L native=$LIPC_STUB_DIR"
echo "Cross-compiling $PKG_ID for $TARGET with $GCC..."
cargo build --release --target "$TARGET" -p tailscale

DAEMON_BIN=$ROOT/target/$TARGET/release/$DAEMON
if [ ! -x "$DAEMON_BIN" ]; then
    echo "error: expected $DAEMON_BIN after cargo build" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
PKG_STAGING=$WORKDIR/pkg
mkdir -p "$PKG_STAGING"

rsync -a \
    --exclude 'waf/waf-base.js' \
    --exclude 'waf/waf-base.css' \
    --exclude pack.env \
    "$KPM_DIR/" "$PKG_STAGING/"

mkdir -p "$PKG_STAGING/${PKG_ID}/sbin" "$PKG_STAGING/common" \
    "$PKG_STAGING/waf" "$PKG_STAGING/${PKG_ID}/scripts"
cp "$DAEMON_BIN" "$PKG_STAGING/${PKG_ID}/sbin/$DAEMON"
chmod +x "$PKG_STAGING/${PKG_ID}/sbin/$DAEMON"

for spec in ${EXTRA_BINS:-}; do
    name=${spec%%:*}
    dest=${spec#*:}
    src=$ROOT/target/$TARGET/release/$name
    if [ ! -x "$src" ]; then
        echo "error: extra bin $src not found after cargo build" >&2
        exit 1
    fi
    mkdir -p "$PKG_STAGING/$(dirname "$dest")"
    cp "$src" "$PKG_STAGING/$dest"
    chmod +x "$PKG_STAGING/$dest"
done

cp "$ROOT/common/pkg-lib.sh" "$PKG_STAGING/common/pkg-lib.sh"
cp "$ROOT/common/pkg-lib.sh" "$PKG_STAGING/${PKG_ID}/scripts/pkg-lib.sh"
cp "$KPM_DIR/pkg.env" "$PKG_STAGING/${PKG_ID}/scripts/pkg.env"
cp "$ROOT/common/waf-base.js" "$PKG_STAGING/waf/waf-base.js"
cp "$ROOT/common/waf-base.css" "$PKG_STAGING/waf/waf-base.css"

if [ -n "${VERSION_FILE:-}" ]; then
    mkdir -p "$PKG_STAGING/$(dirname "$VERSION_FILE")"
    echo "$TS_VERSION" > "$PKG_STAGING/$VERSION_FILE"
fi

python3 - "$PKG_STAGING/manifest.json" "$KPM_DIR/manifest.json" "$PKG_VERSION" <<'EOF'
import json, sys
staging, source, version = sys.argv[1], sys.argv[2], sys.argv[3]
encoded = [int(part) for part in version.split(".")]
for path in (staging, source):
    with open(path) as f:
        manifest = json.load(f)
    manifest["version"] = encoded
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
EOF

python3 - "$PKG_STAGING/waf/index.html" "$KPM_DIR/waf/index.html" "$PKG_VERSION" <<'EOF'
import re, sys
for path in sys.argv[1:3]:
    with open(path) as f:
        text = f.read()
    text, _ = re.subn(r"((?:waf-base\.css|waf-base\.js|style\.css|script\.js))(\?v=[0-9.]+)?", r"\1?v=" + sys.argv[3], text)
    with open(path, "w") as f:
        f.write(text)
EOF

mkdir -p "$DIST_DIR" "$WORKDIR/out"
python3 "$ROOT/tools/kpm-helper.py" package pack "$PKG_STAGING" "$WORKDIR/out"
KPKG=$(find "$WORKDIR/out" -name '*.kpkg' | head -n 1)
if [ -z "$KPKG" ]; then
    echo "error: kpm-helper did not produce a .kpkg" >&2
    exit 1
fi
cp "$KPKG" "$DIST_DIR/"
echo "Done. Built $DIST_DIR/$(basename "$KPKG")."
