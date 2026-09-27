#!/bin/sh
# Prints current Tailscale status to the screen and to var/status_log.txt.
# Not wired to a scriptlet by default, but handy to run manually over SSH.

BIN=/mnt/us/tailscale/bin
VAR=/mnt/us/tailscale/var
LOG=$VAR/status_log.txt

mkdir -p "$VAR"

echo "[$(date)] Tailscale status" >"$LOG"
"$BIN/tailscale" status >>"$LOG" 2>&1
cat "$LOG"
