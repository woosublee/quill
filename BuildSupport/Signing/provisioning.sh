#!/usr/bin/env bash
# Reads a provisioning profile for signing.
#
#   provisioning.sh entitlements <profile> <bundle-id> <environment> <container> <identity> <base> <output>
#     Writes <base> plus the iCloud entitlements the profile allows to <output>.
#     Fails, writing nothing, when the profile is for another app, does not
#     allow the container, CloudKit, or the environment, does not list the
#     signing identity or this Mac, or has expired. <identity> is the
#     codesign identity: a SHA-1 hash or a name from the keychain.
#   provisioning.sh identity <profile>
#     Prints the SHA-1 of the first keychain signing identity whose
#     certificate the profile lists.
set -euo pipefail

buddy=/usr/libexec/PlistBuddy
workdir="$(mktemp -d -t quill-provisioning)"
trap 'rm -rf "$workdir"' EXIT

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
    value "$plist" "$key" || true
  fi
}

contains_line() {
  grep -Fxq -- "$1"
}

# SHA-1 hashes of the certificates the profile lists, one per line.
profile_certificate_hashes() {
  local decoded="$1" count=0
  while plutil -extract "DeveloperCertificates.$count" raw -o "$workdir/cert" "$decoded" 2>/dev/null; do
    base64 -D -i "$workdir/cert" | shasum -a 1 | awk '{ print toupper($1) }'
    count=$((count + 1))
  done
}

# Valid keychain signing identities as "HASH name" lines.
keychain_identities() {
  security find-identity -v -p codesigning | awk '/^ *[0-9]+\)/ { hash = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); print hash " " $0 }'
}

# Hashes of the keychain identities a codesign identity argument names.
identity_hashes() {
  local identity="$1"
  if printf '%s' "$identity" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
    printf '%s\n' "$identity" | tr '[:lower:]' '[:upper:]'
  else
    keychain_identities | awk -v name="$identity" 'index($0, name) { print $1 }'
  fi
}

this_mac_udid() {
  system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ { print $2; exit }'
}

write_entitlements() {
  local profile="$1" bundle_id="$2" environment="$3" container="$4" identity="$5" base="$6" output="$7"
  local decoded="$workdir/profile.plist" team app_id expires devices udid
  decode_profile "$profile" "$decoded"

  team="$(value "$decoded" "TeamIdentifier:0")" || fail "profile has no team"
  app_id="$(value "$decoded" "Entitlements:com.apple.application-identifier")" || fail "profile has no app identifier"
  [ "$app_id" = "$team.$bundle_id" ] || fail "profile is for $app_id, not $team.$bundle_id"

  expires="$(plutil -extract ExpirationDate raw -o - "$decoded")" || fail "profile has no expiration date"
  [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \< "$expires" ] || fail "profile expired on $expires"

  items "$decoded" "Entitlements:com.apple.developer.icloud-container-identifiers" | contains_line "$container" ||
    fail "profile does not allow container $container"
  items "$decoded" "Entitlements:com.apple.developer.icloud-services" | grep -Fxq -e '*' -e CloudKit ||
    fail "profile does not allow CloudKit"
  items "$decoded" "Entitlements:com.apple.developer.icloud-container-environment" | contains_line "$environment" ||
    fail "profile does not allow the $environment environment"

  profile_certificate_hashes "$decoded" > "$workdir/profile-certs"
  identity_hashes "$identity" | grep -Fxq -f "$workdir/profile-certs" ||
    fail "profile does not list the signing identity $identity"

  # Development profiles list the Macs they run on; Developer ID lists none.
  devices="$(items "$decoded" "ProvisionedDevices")"
  if [ -n "$devices" ]; then
    udid="$(this_mac_udid)"
    [ -n "$udid" ] && printf '%s\n' "$devices" | contains_line "$udid" ||
      fail "this Mac (${udid:-unknown}) is not registered in the profile"
  fi

  local entitlements="$workdir/entitlements.plist"
  cp "$base" "$entitlements"
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

select_identity() {
  local profile="$1" decoded="$workdir/profile.plist" hash
  decode_profile "$profile" "$decoded"
  keychain_identities | awk '{ print $1 }' > "$workdir/keychain"
  while read -r hash; do
    if contains_line "$hash" < "$workdir/keychain"; then
      printf '%s\n' "$hash"
      return 0
    fi
  done < <(profile_certificate_hashes "$decoded")
  fail "no signing identity in the keychain matches a certificate in $profile"
}

case "${1:-}" in
  entitlements)
    [ "$#" -eq 8 ] || fail "usage: provisioning.sh entitlements <profile> <bundle-id> <environment> <container> <identity> <base> <output>"
    write_entitlements "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    ;;
  identity)
    [ "$#" -eq 2 ] || fail "usage: provisioning.sh identity <profile>"
    select_identity "$2"
    ;;
  *)
    fail "usage: provisioning.sh entitlements|identity ..."
    ;;
esac
