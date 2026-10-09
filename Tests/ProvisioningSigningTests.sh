#!/usr/bin/env bash
set -euo pipefail

script="BuildSupport/Signing/provisioning.sh"
temporary_dir="$(mktemp -d -t quill-provisioning-test)"
trap 'rm -rf "$temporary_dir"' EXIT

fail() {
  echo "ProvisioningSigningTests: $*" >&2
  exit 1
}

# A synthetic, unsigned profile: the script reads plain plists as well as
# signed ones, so no real profile or certificate is needed here.
write_profile() {
  local path="$1" app_id="$2" environments="$3" expires="$4"
  local environment_items=""
  for environment in $environments; do
    environment_items+="<string>$environment</string>"
  done
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>TeamIdentifier</key><array><string>TEAMID1234</string></array>
  <key>ExpirationDate</key><date>$expires</date>
  <key>DeveloperCertificates</key>
  <array>
    <data>$(printf 'synthetic-cert-a' | base64)</data>
    <data>$(printf 'synthetic-cert-b' | base64)</data>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key><string>$app_id</string>
    <key>com.apple.developer.team-identifier</key><string>TEAMID1234</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.com.example.notes</string></array>
    <key>com.apple.developer.icloud-services</key><string>*</string>
    <key>com.apple.developer.icloud-container-environment</key>
    <array>$environment_items</array>
  </dict>
</dict>
</plist>
PLIST
}

base="Quill.entitlements"
profile="$temporary_dir/dev.provisionprofile"
write_profile "$profile" "TEAMID1234.com.example.notes.dev" "Production Development" "2099-01-01T00:00:00Z"

out="$temporary_dir/signing.entitlements"
bash "$script" entitlements "$profile" com.example.notes.dev Development iCloud.com.example.notes "$base" "$out"
plutil -lint "$out" >/dev/null

read_key() {
  plutil -extract "$1" raw -o - "$out"
}

[ "$(read_key com\\.apple\\.application-identifier)" = "TEAMID1234.com.example.notes.dev" ] || fail "application identifier"
[ "$(read_key com\\.apple\\.developer\\.team-identifier)" = "TEAMID1234" ] || fail "team identifier"
[ "$(read_key com\\.apple\\.developer\\.icloud-container-identifiers.0)" = "iCloud.com.example.notes" ] || fail "container"
[ "$(read_key com\\.apple\\.developer\\.icloud-services.0)" = "CloudKit" ] || fail "CloudKit service"
[ "$(read_key com\\.apple\\.developer\\.icloud-container-environment)" = "Development" ] || fail "environment"
# The base entitlements are kept unchanged.
for key in com\\.apple\\.security\\.device\\.audio-input com\\.apple\\.security\\.cs\\.disable-library-validation com\\.apple\\.security\\.personal-information\\.calendars; do
  [ "$(read_key "$key")" = "true" ] || fail "base entitlement $key"
done

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $description"
  fi
}

expect_failure "profile for another app" \
  bash "$script" entitlements "$profile" com.example.other Development iCloud.com.example.notes "$base" "$out"
expect_failure "container the profile does not allow" \
  bash "$script" entitlements "$profile" com.example.notes.dev Development iCloud.com.example.other "$base" "$out"

production_only="$temporary_dir/production.provisionprofile"
write_profile "$production_only" "TEAMID1234.com.example.notes" "Production" "2099-01-01T00:00:00Z"
expect_failure "Development on a Production-only profile" \
  bash "$script" entitlements "$production_only" com.example.notes Development iCloud.com.example.notes "$base" "$out"
bash "$script" entitlements "$production_only" com.example.notes Production iCloud.com.example.notes "$base" "$out"
[ "$(read_key com\\.apple\\.developer\\.icloud-container-environment)" = "Production" ] || fail "production environment"

expired="$temporary_dir/expired.provisionprofile"
write_profile "$expired" "TEAMID1234.com.example.notes" "Production" "2001-01-01T00:00:00Z"
expect_failure "expired profile" \
  bash "$script" entitlements "$expired" com.example.notes Production iCloud.com.example.notes "$base" "$out"

expect_failure "missing profile" \
  bash "$script" entitlements "$temporary_dir/missing.provisionprofile" com.example.notes Production iCloud.com.example.notes "$base" "$out"

# The signing identity is the keychain identity whose certificate the
# profile lists.
cert_b_hash="$(printf 'synthetic-cert-b' | shasum -a 1 | awk '{ print toupper($1) }')"
identity="$(QUILL_SIGNING_IDENTITY_HASHES="0000000000000000000000000000000000000000
$cert_b_hash" bash "$script" identity "$profile")"
[ "$identity" = "$cert_b_hash" ] || fail "identity selection"
expect_failure "no matching identity" \
  env QUILL_SIGNING_IDENTITY_HASHES="0000000000000000000000000000000000000000" bash "$script" identity "$profile"

echo "ProvisioningSigningTests passed"
