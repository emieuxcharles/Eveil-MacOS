#!/bin/bash
set -euo pipefail
APP="${1:-/Applications/Eveil2.app}"
STATE=$(/bin/launchctl print system/fr.eveil2.daemon)
[[ "$STATE" == *'state = running'* ]] || { echo 'FAIL: service is not running'; exit 1; }
REPLY=$("$APP/Contents/MacOS/Eveil2" --probe)
/usr/bin/python3 -c 'import json,sys; x=json.loads(sys.argv[1]); assert x["euid"] == 0 and x["pid"] > 1 and x["protocolVersion"] == 1; print("PASS: authenticated root daemon", x["pid"])' "$REPLY"
