#!/bin/sh
# Connects tailscale (the daemon must already be running) and snapshots the
# node state on success. This is the single connect entry point: the WAF
# Start button (via start.sh) and manual SSH both use it, so the state
# backup is ALWAYS taken on a successful connect - a later state-file loss
# then self-heals without re-registering a new node.
#
# The auth key handles first login and NeedsLogin/LoggedOut recovery.
# A reusable key is required after the node is removed from the admin
# console. The key is passed as file: so it is not on the process list,
# and surrounding whitespace is stripped first.

. "$(dirname "$0")/tailscale-args.sh"

BIN=/mnt/us/tailscale/bin
VAR=/mnt/us/tailscale/var
AUTH_KEY=$VAR/auth.key
LOG=$VAR/start_log.txt

eips_log() {
    echo "$1" >>"$LOG"
    # eips prints a harmless "swipe feature is not supported in this
    # platform" notice on some devices (e.g. Oasis 10th gen); redirect both
    # stdout and stderr so it doesn't clutter interactive/manual runs.
    eips 0 22 "$(printf '%-50s' "$1")" >/dev/null 2>&1
}

# The hostname configured in up.args (default --hostname=kindle). Applied
# after every successful connect so a node the control plane deduped (e.g.
# a fresh registration) is renamed back to the stable name.
TS_HOST=$(echo "$UP_ARGS" | grep -o -- '--hostname=[^ ]*' | head -1 | cut -d= -f2)

# file:/path form accepted by `tailscale up --auth-key`. Empty after
# trimming is a failure, not a login attempt.
prepare_auth_key() {
    keyfile=/var/local/tailscale/auth.key
    mkdir -p /var/local/tailscale
    tr -d '[:space:]' < "$AUTH_KEY" > "$keyfile" || return 1
    chmod 600 "$keyfile" || return 1
    [ -s "$keyfile" ] || return 1
    printf '%s' "file:$keyfile"
}

ts_connected() {
    eips_log "Tailscale connected!"
    [ -n "$TS_HOST" ] && "$BIN/tailscale" set --hostname="$TS_HOST" >>"$LOG" 2>&1 || true
    # Always snapshot the node state on a successful connect so a later
    # state-file loss restores from here instead of re-registering.
    [ -s "$VAR/tailscaled.state" ] && cp -a "$VAR/tailscaled.state" "$VAR/tailscaled.state.bak" 2>/dev/null || true
    exit 0
}

# Was there a node identity BEFORE this run? The plain `up` below makes a
# fresh tailscaled CREATE a pending-login state file, so "state exists"
# must be judged before the attempt - otherwise a first-time setup would be
# misread as "state exists" and never auto-authenticate.
HAD_STATE=false
if [ -s "$VAR/tailscaled.state" ] || [ -s "$VAR/tailscaled.state.bak" ]; then
    HAD_STATE=true
fi

# Registered node: try reconnecting without re-authenticating first (works
# once the node is registered and key expiry is disabled). Timeout avoids
# hanging forever on a fresh/reset node, where `tailscale up` prints a login
# URL and waits.
if [ "$HAD_STATE" = true ]; then
    if timeout 30 "$BIN/tailscale" up $UP_ARGS >>"$LOG" 2>&1; then
        ts_connected
    fi
fi

# A failed plain `up` does NOT always mean the node needs to re-authenticate:
# on a slow boot (wifi still settling) it can simply time out. Only use the
# auth key after status explicitly reports a login is required.
if "$BIN/tailscale" status --json 2>/dev/null | grep -qE '"BackendState": *"(NeedsLogin|LoggedOut)"'; then
    if [ "$HAD_STATE" = false ]; then
        if [ -s "$AUTH_KEY" ]; then
            key_arg=$(prepare_auth_key) || {
                eips_log "Auth key in $AUTH_KEY is empty"
                rm -f "$VAR/tailscaled.state"
                exit 1
            }
            eips_log "First-time setup - authenticating with auth key..."
            if timeout 30 "$BIN/tailscale" up $UP_ARGS --auth-key="$key_arg" >>"$LOG" 2>&1; then
                ts_connected
            fi
            eips_log "Auth key login failed - check $VAR/tailscaled.log"
            # The pending-login state was created by this run; remove it so
            # the next attempt retries first-time auth instead of getting
            # stuck in "state exists - refusing to auto-register".
            rm -f "$VAR/tailscaled.state"
            exit 1
        fi
        eips_log "Fill in $AUTH_KEY and retry"
        rm -f "$VAR/tailscaled.state"
        exit 1
    fi
    if [ -s "$AUTH_KEY" ]; then
        key_arg=$(prepare_auth_key) || {
            eips_log "Auth key in $AUTH_KEY is empty"
            exit 1
        }
        eips_log "Login required - authenticating with saved auth key..."
        if timeout 30 "$BIN/tailscale" up $UP_ARGS --auth-key="$key_arg" >>"$LOG" 2>&1; then
            ts_connected
        fi
        eips_log "Auth key re-login failed - check $VAR/tailscaled.log"
        exit 1
    fi
    eips_log "Not logged in and no auth key is saved - add one to $AUTH_KEY and retry"
    exit 1
fi

eips_log "Reconnect failed (node is registered - not re-authenticating, retry next start) - check $VAR/tailscaled.log"
exit 1
