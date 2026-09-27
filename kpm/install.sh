#!/bin/sh
# Install Tailscale under /mnt/us/tailscale.
#
# Official tailscale/tailscaled binaries are downloaded last from
# pkgs.tailscale.com. A failed download must not fail this script: KPM
# deletes the package when install.sh exits nonzero. The warning path
# leaves the app in place so a later reinstall can retry the download.
# An existing auth key and node state are left in place.

set -e

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
if [ -f "$SCRIPT_DIR/common/pkg-lib.sh" ]; then
    . "$SCRIPT_DIR/common/pkg-lib.sh"
elif [ -f "$SCRIPT_DIR/../common/pkg-lib.sh" ]; then
    . "$SCRIPT_DIR/../common/pkg-lib.sh"
else
    echo "error: pkg-lib.sh not found" >&2
    exit 1
fi
. "$SCRIPT_DIR/pkg.env"

mkdir -p "$DEST/bin" "$DEST/sbin" "$DEST/scripts" "$DEST/var" /mnt/us/documents

pkg_install_files

# bin/ survives an upgrade. Remove the outbound SSH client shipped by
# older packages; Tailscale SSH into the Kindle does not use it.
rm -f "$DEST/bin/ssh" "$DEST/bin/scp" "$DEST/bin/tunnel" "$DEST/bin/ssh-keygen" \
    "$DEST/scripts/ts-ssh.sh" /var/local/kmc/utils/tsctl

pkg_seed_if_missing ./tailscale/auth.key.default "$DEST/var/auth.key"
pkg_seed_if_missing ./tailscale/up.args.default "$DEST/var/up.args"

if [ -s "$DEST/var/tailscaled.state" ] && [ ! -s "$DEST/var/tailscaled.state.bak" ]; then
    echo "Seeding tailscaled.state.bak from existing state..."
    cp -a "$DEST/var/tailscaled.state" "$DEST/var/tailscaled.state.bak"
fi

echo "Registering the Tailscale WAF..."
if [ -x "$DEST/scripts/register-waf.sh" ]; then
    "$DEST/scripts/register-waf.sh" || echo "warning: WAF registration failed - is sqlite3 available? Tapping the Home screen icon will retry this." >&2
fi

pkg_install_upstart

# Remove the legacy watchdog so only an explicit Start can launch tailscaled.
if [ -e /etc/upstart/tailscale-watchdog.conf ]; then
    pkg_remount_rw
    watchdog_removed=0
    rm -f /etc/upstart/tailscale-watchdog.conf && watchdog_removed=1
    pkg_remount_ro
    if [ "$watchdog_removed" != 1 ]; then
        echo "error: could not remove the automatic Tailscale startup job" >&2
        exit 1
    fi
fi
rm -f "$DEST/scripts/watchdog.sh"
initctl reload-configuration 2>/dev/null || true

# --- Network-dependent: download the official tailscale binaries -----------

TS_VER=$(cat ./tailscale/version 2>/dev/null || true)
case "$TS_VER" in
'' | *[!0-9.]*)
    echo "error: ./tailscale/version missing or invalid in this kpkg - rebuild with just package" >&2
    exit 1
    ;;
esac
TS_URL="https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_arm.tgz"

# A failed download must NOT fail the install: KPM treats a nonzero
# install.sh exit as a failed install and deletes the package directory
# (and runs uninstall.sh), which would break `kpm launch tailscale`
# entirely. Warn loudly instead - the app is already installed and the
# binaries can be fetched by reinstalling when the network is back.
install_tailscale_binaries() {
    url=$1
    out=$2
    bin_dir=$3
    if command -v curl >/dev/null 2>&1; then
        # Never bypass certificate verification: these binaries run as root.
        curl -fL --progress-bar -o "$out" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url" || return 1
    else
        echo "error: need curl or wget on the device to download the tailscale binaries" >&2
        return 1
    fi
    tar xzf "$out" -C "$(dirname "$out")" || return 1
    cp -f "$(dirname "$out")/tailscale_${TS_VER}_arm/tailscale" \
        "$(dirname "$out")/tailscale_${TS_VER}_arm/tailscaled" "$bin_dir/" || return 1
    chmod +x "$bin_dir/tailscale" "$bin_dir/tailscaled" || return 1
    printf '%s\n' "$TS_VER" >"$bin_dir/.tailscale-version" || return 1
    return 0
}

INSTALLED_TS_VER=$(cat "$DEST/bin/.tailscale-version" 2>/dev/null || true)
if [ -x "$DEST/bin/tailscale" ] && [ -x "$DEST/bin/tailscaled" ] \
    && [ "$INSTALLED_TS_VER" = "$TS_VER" ]; then
    echo "Tailscale ${TS_VER} binaries already present at $DEST/bin - keeping them"
else
    echo "Downloading tailscale ${TS_VER} (arm) from pkgs.tailscale.com..."
    TMP="$DEST/.download"
    rm -rf "$TMP"
    mkdir -p "$TMP"
    if ! install_tailscale_binaries "$TS_URL" "$TMP/tailscale.tgz" "$DEST/bin"; then
        echo "warning: could not download the tailscale binaries (is the Kindle online?) - the app is installed but tailscale won't start until they are present; reinstall this package when the network is available." >&2
    else
        echo "Installed tailscale/tailscaled ${TS_VER} to $DEST/bin"
    fi
    rm -rf "$TMP"
fi

# An upgrade's stop.sh leaves this temporary watchdog guard while package
# files and binaries are replaced. A user-created var/stopped marker remains.
rm -f "$DEST/var/maintenance"

echo "Tailscale installed. Fill in $DEST/var/auth.key with a Tailscale auth"
echo "key (https://tailscale.com/kb/1085/auth-keys), then tap the Tailscale"
echo "scriptlet on your Home screen for status/start/stop."
echo "The WAF runs start/stop/status via the bundled tsctl runner"
echo "(LIPC service dev.qingshan.tsctl), so nothing else needs installing."

# Stop last: a legacy watchdog job may still own tailscaled.
stop tailscale-watchdog 2>/dev/null || true
