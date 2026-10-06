#!/bin/bash
# Submits a file to Apple's notary service using the "notarytool-profile"
# stored in $KEYCHAIN_PATH, and prints Apple's log when it is not accepted.
set -euo pipefail

file="${1:?usage: notarize.sh <zip-or-dmg>}"
: "${KEYCHAIN_PATH:?KEYCHAIN_PATH must point at the keychain holding notarytool-profile}"

result="$(xcrun notarytool submit "$file" \
  --keychain-profile "notarytool-profile" \
  --keychain "$KEYCHAIN_PATH" \
  --wait \
  --output-format json)" || true

submission_id="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
status="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
echo "Notarization submission ${submission_id:-unknown}: ${status:-unknown}"

if [ "$status" != "Accepted" ]; then
  printf '%s\n' "$result" >&2
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" \
      --keychain-profile "notarytool-profile" \
      --keychain "$KEYCHAIN_PATH" >&2 || true
  fi
  exit 1
fi
