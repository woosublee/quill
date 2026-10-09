#!/usr/bin/env bash
# Reads a provisioning profile for signing.
#
#   provisioning.sh entitlements <profile> <bundle-id> <environment> <container> <base> <output>
#     Writes <base> plus the iCloud entitlements the profile allows to <output>.
#     Fails when the profile is for another app or team, does not allow the
#     container or environment, or has expired.
#   provisioning.sh identity <profile>
#     Prints the SHA-1 of the first keychain signing identity whose
#     certificate the profile lists.
set -euo pipefail

buddy=/usr/libexec/PlistBuddy

fail() {
  echo "provisioning.sh: $*" >&2
  exit 1
}

# Signed profiles are CMS envelopes; plain plists are accepted for tests.
decode_profile() {
  local profile="$1" output="$2"
  [ -f "$profile" ] || fail "profile not found: $profile"
  if ! security cms -D -i "$profile" > "$output" 2>/dev/null; then
    plutil -convert xml1 -o "$output" "$profile" 2>/dev/null || fail "cannot read profile: $profile"
  fi
}

value() {
  "$buddy" -c "Print :$2" "$1" 2>/dev/null
}

# Prints each array item on its own line, or the single value of a string.
items() {
  local plist="$1" key="$2" count=0
  if value "$plist" "$key:0" >/dev/null; then
    while value "$plist" "$key:$count"; do
      count=$((count + 1))
    done
  else
    value "$plist" "$key"
  fi
}

contains_line() {
  grep -Fxq -- "$1"
}

write_entitlements() {
  local profile="$1" bundle_id="$2" environment="$3" container="$4" base="$5" output="$6"
  local workdir decoded team app_id expires
  workdir="$(mktemp -d -t quill-provisioning)"
  trap 'rm -rf "$workdir"' RETURN
  decoded="$workdir/profile.plist"
  decode_profile "$profile" "$decoded"

  team="$(value "$decoded" "TeamIdentifier:0")" || fail "profile has no team"
  app_id="$(value "$decoded" "Entitlements:com.apple.application-identifier")" || fail "profile has no app identifier"
  [ "$app_id" = "$team.$bundle_id" ] || fail "profile is for $app_id, not $team.$bundle_id"

  expires="$(plutil -extract ExpirationDate raw -o - "$decoded")" || fail "profile has no expiration date"
  [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \< "$expires" ] || fail "profile expired on $expires"

  items "$decoded" "Entitlements:com.apple.developer.icloud-container-identifiers" | contains_line "$container" ||
    fail "profile does not allow container $container"
  items "$decoded" "Entitlements:com.apple.developer.icloud-container-environment" | contains_line "$environment" ||
    fail "profile does not allow the $environment environment"

  cp "$base" "$workdir/entitlements.plist"
  local entitlements="$workdir/entitlements.plist"
  "$buddy" \
    -c "Add :com.apple.application-identifier string $app_id" \
    -c "Add :com.apple.developer.team-identifier string $team" \
    -c "Add :com.apple.developer.icloud-container-identifiers array" \
    -c "Add :com.apple.developer.icloud-container-identifiers:0 string $container" \
    -c "Add :com.apple.developer.icloud-services array" \
    -c "Add :com.apple.developer.icloud-services:0 string CloudKit" \
    -c "Add :com.apple.developer.icloud-container-environment string $environment" \
    "$entitlements" >/dev/null
  plutil -lint "$entitlements" >/dev/null
  mkdir -p "$(dirname "$output")"
  mv "$entitlements" "$output"
}

keychain_identity_hashes() {
  if [ -n "${QUILL_SIGNING_IDENTITY_HASHES:-}" ]; then
    printf '%s\n' "$QUILL_SIGNING_IDENTITY_HASHES"
  else
    security find-identity -v -p codesigning | awk '/^ *[0-9]+\)/ { print $2 }'
  fi
}

select_identity() {
  local profile="$1" workdir decoded count=0 hash identities
  workdir="$(mktemp -d -t quill-provisioning)"
  trap 'rm -rf "$workdir"' RETURN
  decoded="$workdir/profile.plist"
  decode_profile "$profile" "$decoded"
  identities="$(keychain_identity_hashes)"
  while plutil -extract "DeveloperCertificates.$count" raw -o "$workdir/cert" "$decoded" 2>/dev/null; do
    hash="$(base64 -D -i "$workdir/cert" | shasum -a 1 | awk '{ print toupper($1) }')"
    if printf '%s\n' "$identities" | contains_line "$hash"; then
      printf '%s\n' "$hash"
      return 0
    fi
    count=$((count + 1))
  done
  fail "no signing identity in the keychain matches a certificate in $profile"
}

case "${1:-}" in
  entitlements)
    [ "$#" -eq 7 ] || fail "usage: provisioning.sh entitlements <profile> <bundle-id> <environment> <container> <base> <output>"
    write_entitlements "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  identity)
    [ "$#" -eq 2 ] || fail "usage: provisioning.sh identity <profile>"
    select_identity "$2"
    ;;
  *)
    fail "usage: provisioning.sh entitlements|identity ..."
    ;;
esac
