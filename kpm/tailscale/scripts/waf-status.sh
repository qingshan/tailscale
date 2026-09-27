#!/bin/sh
# Write status.json for the WAF to poll. kindle.messaging has no
# synchronous result, and the device has no jq, so BackendState is taken
# with grep. Liveness is the CLI's own JSON: an empty reply means the
# daemon is down. A normal stop leaves error empty so the page can show
# Stopped. Daemon stderr stays out of this file (it is full of benign
# warnings, and unescaped log bytes break JSON.parse).

. "$(dirname -- "$0")/json-escape.sh"

# Host e2e points these at a fixture. On the Kindle they stay unset.
BIN=${TS_E2E_BIN:-/mnt/us/tailscale/bin}
VAR=${TS_E2E_VAR:-/mnt/us/tailscale/var}
OUT=${TS_E2E_STATUS:-/var/local/mesquite/tailscale/status.json}

RUNNING=false
BACKEND_STATE="Stopped"
ERROR=""

# Missing binaries (e.g. the install-time download failed) are the most
# common reason a fresh install shows "Stopped" - report them explicitly.
if [ ! -x "$BIN/tailscaled" ] || [ ! -x "$BIN/tailscale" ]; then
    ERROR="tailscale binaries missing - reinstall the package while the Kindle is online"
    BACKEND_STATE="Binaries missing"
else
    # Only a reachable daemon answers on its socket, so non-empty JSON here
    # is proof it is running - no process-name guessing. timeout guards
    # against a wedged daemon blocking the socket forever.
    JSON=$(timeout 10 "$BIN/tailscale" status --json 2>/dev/null)
    if [ -n "$JSON" ]; then
        RUNNING=true
        # `tailscale status --json` is pretty-printed (json.MarshalIndent),
        # so allow whitespace after the colon.
        BACKEND_STATE=$(echo "$JSON" | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -z "$BACKEND_STATE" ] && BACKEND_STATE="Starting"
    elif [ -f "$VAR/start_log.txt" ] && grep -qiE 'failed|missing|error' "$VAR/start_log.txt"; then
        # Last start failed. Do not treat a quiet stop the same way: a
        # leftover tailscaled.log is normal after Stop.
        ERROR=$(tail -n 5 "$VAR/start_log.txt" 2>/dev/null | tr '\n' ' ')
        BACKEND_STATE="Start failed"
    fi
fi

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "{\"running\":$RUNNING,\"backendState\":$(json_string "$BACKEND_STATE"),\"updatedAt\":$(date +%s),\"error\":$(json_string "$ERROR")}" >"$OUT"
