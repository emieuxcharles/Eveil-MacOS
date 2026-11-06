#!/bin/bash
set -euo pipefail
APP="${1:-/Applications/Eveil.app}"
STATE=$(/bin/launchctl print system/fr.eveil2.daemon)
[[ "$STATE" == *'state = running'* ]] || { echo 'FAIL: service is not running'; exit 1; }
REPLY=$("$APP/Contents/MacOS/Eveil2" --probe)
/usr/bin/python3 -c 'import json,sys; x=json.loads(sys.argv[1]); import re; expected=int(re.search(r"^\s*pid = (\d+)",sys.argv[2],re.M).group(1)); assert x["euid"] == 0 and x["pid"] == expected and x["protocolVersion"] == 1; print("PASS: authenticated root daemon", x["pid"])' "$REPLY" "$STATE"
