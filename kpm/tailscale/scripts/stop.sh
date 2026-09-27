#!/bin/sh
# Disconnects from the tailnet and stops tailscaled, keeping the node identity.

BIN=/mnt/us/tailscale/bin
VAR=/mnt/us/tailscale/var
LOG=$VAR/stop_log.txt

mkdir -p "$VAR"
# Keep shutdown markers for compatibility with older package versions.
if [ "${1:-}" = "--upgrade" ]; then
    touch "$VAR/maintenance"
else
    touch "$VAR/stopped"
fi

eips_log() {
    echo "$1" >>"$LOG"
    # eips prints a harmless "swipe feature is not supported in this
    # platform" notice on some devices (e.g. Oasis 10th gen); redirect both
    # stdout and stderr so it doesn't clutter interactive/manual runs.
    eips 0 22 "$(printf '%-50s' "$1")" >/dev/null 2>&1
}

echo "[$(date)] Stopping Tailscale..." >"$LOG"
eips_log "Stopping Tailscale..."

# `tailscale down` is a state change: the daemon rewrites tailscaled.state.
# Killing it immediately after (as an upgrade's stop.sh does) can truncate
# that write on the FAT user store, corrupting the node identity and forcing
# a NeedsLogin on the next start. Give the state write time to flush first.
"$BIN/tailscale" down >>"$LOG" 2>&1
sleep 2

eips_log "Stopping tailscaled..."

# pkill returns non-zero if nothing was running, which is fine here.
pkill tailscaled >>"$LOG" 2>&1
sleep 3
rm -f /var/run/tailscale/tailscaled.sock

"$BIN/tailscaled" --statedir="$VAR" -cleanup >>"$LOG" 2>&1
rm -f /var/run/tailscale/tailscaled.sock

eips_log "Tailscale stopped"
