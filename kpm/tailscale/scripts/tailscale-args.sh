# Shared split of /mnt/us/tailscale/var/up.args into tailscaled flags
# (DAEMON_ARGS) and `tailscale up` flags (UP_ARGS). Source this file - it is
# the single source of truth for the split so it is never duplicated.
#
# up.args holds one line covering both, e.g. --tun=userspace-networking is a
# tailscaled option, while --hostname/--ssh go to `tailscale up`.

TS_VAR=/mnt/us/tailscale/var

DAEMON_ARGS=""
UP_ARGS=""
if [ -f "$TS_VAR/up.args" ]; then
    for arg in $(cat "$TS_VAR/up.args"); do
        case "$arg" in
        --tun=* | --socks5-server=* | --outbound-http-proxy-listen=* | --port=* | --socket=* | --state=* | --statedir=* | --verbose=*)
            DAEMON_ARGS="$DAEMON_ARGS $arg"
            ;;
        *)
            UP_ARGS="$UP_ARGS $arg"
            ;;
        esac
    done
fi

# Fall back to plain userspace networking if up.args is missing/empty.
if [ -z "$DAEMON_ARGS" ]; then
    DAEMON_ARGS="--tun=userspace-networking"
fi
