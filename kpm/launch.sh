#!/bin/sh
# Invoked via `kpm launch tailscale` (called from the scriptlet in
# /mnt/us/documents/tailscale.sh). Opens the Tailscale WAF - a small
# Mesquite app showing connection status with Start/Stop buttons - instead
# of toggling directly.
#
# The WAF is re-registered on every tap rather than just once at install
# time, because /var is tmpfs (wiped on every reboot) and kpm has no
# boot-time hook yet to redo this automatically.

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

if ! pkg_launch_lock; then
    exit 0
fi

LAUNCH_LOG=$DEST/var/launch_log.txt

# The upstart job normally keeps tsctl running, but a launch can predate
# it (or the job write failed at install time) - start the runner on
# demand so the WAF's Start/Stop/Refresh buttons always have a backend.
# Started WITHOUT -n so tsctl double-forks.
if ! pkg_daemon_up; then
    "$DEST/sbin/tsctl" >"$DEST/var/tsctl.err" 2>&1
    sleep 1
    if ! pkg_daemon_up; then
        echo "[$(date)] tsctl failed to start - stderr:" >>"$LAUNCH_LOG"
        tail -n 15 "$DEST/var/tsctl.err" 2>/dev/null >>"$LAUNCH_LOG"
    fi
fi

if ! "$DEST/scripts/register-waf.sh"; then
    echo "[$(date)] register-waf.sh failed - WAF may not launch" >>"$LAUNCH_LOG"
fi

# Seed a fresh status snapshot so the page renders immediately.
"$DEST/scripts/waf-status.sh" 2>/dev/null || true

# register-waf rewrites the page under a mesquite that is already running.
# That process then fails appmgrd's savecontext check and the cover tap
# drops back to Home. Ask appmgrd to stop it. SIGTERM is a crash to
# appmgrd and leaves the Application Error dialog up.
lipc-set-prop com.lab126.appmgrd stop "app://${APP_ID}" >/dev/null 2>&1 || true
_i=0
while [ "$_i" -lt 5 ]; do
    _alive=0
    for _p in /proc/[0-9]*; do
        [ "$(cat "$_p/comm" 2>/dev/null)" = mesquite ] || continue
        case "$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)" in
            *"-l ${APP_ID}"*) _alive=1 ;;
        esac
    done
    [ "$_alive" = 0 ] && break
    _i=$((_i + 1))
    sleep 1
done
pkg_appmgrd_start
