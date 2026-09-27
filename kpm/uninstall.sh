#!/bin/sh
# Stops Tailscale (if running) and removes the package.
#
# KPM also runs this BEFORE an upgrade, as `uninstall.sh upgrade`. In that
# case the downloaded binaries and the user's auth key/up.args/node state
# are kept so the reinstall is instant and never resets credentials - only
# the daemon, upstart job, WAF registration and scriptlet are torn down.

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

pkg_uninstall "$1"
rm -f /var/local/kmc/utils/tsctl
