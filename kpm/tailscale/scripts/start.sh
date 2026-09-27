#!/bin/sh
# Starts tailscaled, then connects via the shared connect.sh (which also
# snapshots the node state on success).
#
# up.args is split by tailscale-args.sh (sourced below) into DAEMON_ARGS
# (passed to tailscaled) and UP_ARGS (passed to `tailscale up`).

. "$(dirname "$0")/tailscale-args.sh"

BIN=/mnt/us/tailscale/bin
VAR=/mnt/us/tailscale/var
AUTH_KEY=$VAR/auth.key
LOG=$VAR/start_log.txt

mkdir -p "$VAR"

eips_log() {
    echo "$1" >>"$LOG"
    # eips prints a harmless "swipe feature is not supported in this
    # platform" notice on some devices (e.g. Oasis 10th gen); redirect both
    # stdout and stderr so it doesn't clutter interactive/manual runs.
    eips 0 22 "$(printf '%-50s' "$1")" >/dev/null 2>&1
}

# Bail out early with a clear message when the binaries never got
# downloaded (the install-time download failure path).
if [ ! -x "$BIN/tailscaled" ] || [ ! -x "$BIN/tailscale" ]; then
    echo "[$(date)] ERROR: tailscale binaries missing at $BIN - reinstall the package while the Kindle is online" >"$LOG"
    eips_log "tailscale binaries missing - reinstall while online"
    exit 1
fi

# Clear the stop marker used by older package versions.
rm -f "$VAR/stopped"

echo "[$(date)] Starting tailscaled..." >"$LOG"

# Kill any existing instance and remove a stale socket so this script can be
# re-run safely without requiring an explicit stop first.
pkill tailscaled 2>/dev/null
sleep 2
rm -f /var/run/tailscale/tailscaled.sock

eips_log "Starting tailscaled..."
# Self-heal a lost node state: without a state file tailscaled starts logged
# out, and any automatic re-auth would register a BRAND-NEW node (renamed
# kindle-2, kindle-3, ... by the console). The live state on the FAT user
# store can vanish on abrupt power events, so restore the last known-good
# snapshot when it is missing or empty.
if [ ! -s "$VAR/tailscaled.state" ] && [ -s "$VAR/tailscaled.state.bak" ]; then
    echo "[$(date)] restoring tailscaled.state from backup" >>"$LOG"
    cp -a "$VAR/tailscaled.state.bak" "$VAR/tailscaled.state"
fi
# Runtime daemon output goes to its own log so start_log.txt stays a clean
# lifecycle log: tailscaled's stderr is full of benign warnings (e.g. the
# auditd netlink message on kernels without the audit facility) that the
# WAF must never mistake for start errors.
: >"$VAR/tailscaled.log"
nohup "$BIN/tailscaled" --statedir="$VAR" $DAEMON_ARGS >>"$VAR/tailscaled.log" 2>&1 &
DAEMON_PID=$!

sleep 3
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    eips_log "tailscaled failed to start - check $VAR/tailscaled.log"
    exit 1
fi

# Connect (up + hostname + state backup) in the shared connect script.
exec "$(dirname "$0")/connect.sh"
