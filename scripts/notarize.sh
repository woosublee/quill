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
  --output-format plist)" || submit_status=$?

submission_id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
status="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
echo "Notarization submission ${submission_id:-unknown}: ${status:-unknown} (notarytool exit $submit_status)"

if [ "$submit_status" -ne 0 ] || [ "$status" != "Accepted" ]; then
  printf '%s\n' "$result" >&2
  if [ -n "$submission_id" ]; then
    if [ "$status" = "In Progress" ]; then
      echo "Still processing. This keychain is deleted after the job, so resume with the API key:" >&2
      echo "  xcrun notarytool wait $submission_id --key <AuthKey.p8> --key-id <ASC_KEY_ID> --issuer <ASC_ISSUER_ID>" >&2
    else
      xcrun notarytool log "$submission_id" \
        --keychain-profile "notarytool-profile" \
        --keychain "$KEYCHAIN_PATH" >&2 || true
    fi
  fi
  exit 1
fi
