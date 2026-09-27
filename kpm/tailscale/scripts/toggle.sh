#!/bin/sh
# Starts Tailscale if it is not running, or stops it if it is already
# running. No longer wired to the Home screen scriptlet (that now opens the
# status/start/stop WAF via launch.sh) - kept for quick manual toggling
# over SSH.

# Liveness is probed through the tailscale CLI (the daemon's own socket),
# not `pgrep tailscaled` - a process-name match can disagree with reality,
# which would make this toggle stop a working daemon.
BIN=/mnt/us/tailscale/bin

if "$BIN/tailscale" status >/dev/null 2>&1; then
    exec "$(dirname "$0")/stop.sh"
else
    exec "$(dirname "$0")/start.sh"
fi
