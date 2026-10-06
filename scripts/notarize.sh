#!/bin/bash
# Submits a file to Apple's notary service using the "notarytool-profile"
# stored in $KEYCHAIN_PATH, and prints Apple's log when it is not accepted.
set -euo pipefail

file="${1:?usage: notarize.sh <zip-or-dmg>}"
: "${KEYCHAIN_PATH:?KEYCHAIN_PATH must point at the keychain holding notarytool-profile}"
timeout="${NOTARIZE_TIMEOUT:-45m}"

submit_status=0
result="$(xcrun notarytool submit "$file" \
  --keychain-profile "notarytool-profile" \
  --keychain "$KEYCHAIN_PATH" \
  --wait \
  --timeout "$timeout" \
  --output-format json)" || submit_status=$?

fields="$(printf '%s' "$result" | /usr/bin/python3 -I -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
print(data.get("id", ""))
print(data.get("status", ""))
')"
submission_id="$(printf '%s\n' "$fields" | sed -n 1p)"
status="$(printf '%s\n' "$fields" | sed -n 2p)"
echo "Notarization submission ${submission_id:-unknown}: ${status:-unknown} (notarytool exit $submit_status)"

if [ "$submit_status" -ne 0 ] || [ "$status" != "Accepted" ]; then
  printf '%s\n' "$result" >&2
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" \
      --keychain-profile "notarytool-profile" \
      --keychain "$KEYCHAIN_PATH" >&2 || true
  fi
  exit 1
fi
