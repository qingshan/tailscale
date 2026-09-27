#!/bin/sh
# Host check for the status.json string encoder used on device.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/kpm/tailscale/scripts/json-escape.sh"

input=$(printf 'a\\b"c\t\n')
out=$(json_string "$input")
python3 - "$out" <<'PY'
import json, sys
got = json.loads(sys.argv[1])
assert got == 'a\\b"c', repr(got)
PY
out=$(json_string '')
python3 - "$out" <<'PY'
import json, sys
assert json.loads(sys.argv[1]) == ""
print("json_string OK")
PY
