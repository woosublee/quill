#!/bin/bash
# Submits a file to Apple's notary service and prints Apple's log when it is
# not accepted. The release workflow sets KEYCHAIN_PATH to its temporary
# keychain holding "notarytool-profile". Locally, leave KEYCHAIN_PATH unset
# and set NOTARIZE_PROFILE to a profile in the login keychain.
set -euo pipefail

file="${1:?usage: notarize.sh <zip-or-dmg>}"
timeout="${NOTARIZE_TIMEOUT:-45m}"

if [ -n "${KEYCHAIN_PATH:-}" ]; then
  profile="notarytool-profile"
  credentials=(--keychain-profile "$profile" --keychain "$KEYCHAIN_PATH")
else
  profile="${NOTARIZE_PROFILE:?set NOTARIZE_PROFILE to a notarytool profile in the login keychain, or KEYCHAIN_PATH in CI}"
  credentials=(--keychain-profile "$profile")
fi

submit_status=0
result="$(xcrun notarytool submit "$file" \
  "${credentials[@]}" \
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
      if [ -n "${KEYCHAIN_PATH:-}" ]; then
        echo "Still processing. This keychain is deleted after the job, so resume with the API key:" >&2
        echo "  xcrun notarytool wait $submission_id --key <AuthKey.p8> --key-id <ASC_KEY_ID> --issuer <ASC_ISSUER_ID>" >&2
      else
        echo "Still processing. Resume with:" >&2
        echo "  xcrun notarytool wait $submission_id --keychain-profile $profile" >&2
      fi
    else
      xcrun notarytool log "$submission_id" "${credentials[@]}" >&2 || true
    fi
  fi
  exit 1
fi
