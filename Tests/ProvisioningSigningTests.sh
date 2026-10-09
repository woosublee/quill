#!/usr/bin/env bash
set -euo pipefail

script="$PWD/BuildSupport/Signing/provisioning.sh"
temporary_dir="$(mktemp -d -t quill-provisioning-test)"
trap 'rm -rf "$temporary_dir"' EXIT

fail() {
  echo "ProvisioningSigningTests: $*" >&2
  exit 1
}

hash_of() {
  printf '%s' "$1" | shasum -a 1 | awk '{ print toupper($1) }'
}

cert_a_hash="$(hash_of synthetic-cert-a)"
cert_b_hash="$(hash_of synthetic-cert-b)"
other_hash="0000000000000000000000000000000000000000"
this_mac="00000000-SYNTHETIC-THIS-MAC"

# Stand-ins for the keychain and the hardware report, found first on PATH.
bin="$temporary_dir/bin"
mkdir -p "$bin"
cat > "$bin/security" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = find-identity ]; then
  printf '%s\n' "$FAKE_IDENTITIES"
  exit 0
fi
exit 1
STUB
cat > "$bin/system_profiler" <<'STUB'
#!/usr/bin/env bash
printf '      Provisioning UDID: %s\n' "$FAKE_UDID"
STUB
chmod +x "$bin/security" "$bin/system_profiler"
export PATH="$bin:$PATH"
export FAKE_IDENTITIES="  1) $other_hash \"Developer ID Application: Synthetic\"
  2) $cert_b_hash \"Apple Development: Synthetic\"
     2 valid identities found"
export FAKE_UDID="$this_mac"

# A synthetic, unsigned profile: the script reads plain plists as well as
# signed ones, so no real profile or certificate is needed here.
write_profile() {
  local path="$1" app_id="$2" environments="$3" expires="$4" devices="$5" services="${6:-*}"
  local environment_items="" device_block=""
  for environment in $environments; do
    environment_items+="<string>$environment</string>"
  done
  if [ -n "$devices" ]; then
    device_block="<key>ProvisionedDevices</key><array>"
    for device in $devices; do
      device_block+="<string>$device</string>"
    done
    device_block+="</array>"
  fi
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
  $device_block
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key><string>$app_id</string>
    <key>com.apple.developer.team-identifier</key><string>TEAMID1234</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.com.example.notes</string></array>
    <key>com.apple.developer.icloud-services</key><string>$services</string>
    <key>com.apple.developer.icloud-container-environment</key>
    <array>$environment_items</array>
  </dict>
</dict>
</plist>
PLIST
}

base="Quill.entitlements"
out="$temporary_dir/signing.entitlements"
profile="$temporary_dir/dev.provisionprofile"
write_profile "$profile" "TEAMID1234.com.example.notes.dev" "Production Development" "2099-01-01T00:00:00Z" "OTHER-MAC $this_mac"

entitlements() {
  bash "$script" entitlements "$@"
}

entitlements "$profile" com.example.notes.dev Development iCloud.com.example.notes "$cert_b_hash" "$base" "$out"
plutil -lint "$out" >/dev/null

read_key() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$out"
}

[ "$(read_key com.apple.application-identifier)" = "TEAMID1234.com.example.notes.dev" ] || fail "application identifier"
[ "$(read_key com.apple.developer.team-identifier)" = "TEAMID1234" ] || fail "team identifier"
[ "$(read_key com.apple.developer.icloud-container-identifiers:0)" = "iCloud.com.example.notes" ] || fail "container"
[ "$(read_key com.apple.developer.icloud-services:0)" = "CloudKit" ] || fail "CloudKit service"
[ "$(read_key com.apple.developer.icloud-container-environment)" = "Development" ] || fail "environment"
# The base entitlements are kept unchanged.
for key in com.apple.security.device.audio-input com.apple.security.cs.disable-library-validation com.apple.security.personal-information.calendars; do
  [ "$(read_key "$key")" = "true" ] || fail "base entitlement $key"
done

# Failures exit non-zero, write no output, and leave no temporary files.
expect_failure() {
  local description="$1"
  shift
  rm -f "$out"
  local before after
  before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'quill-provisioning.*' 2>/dev/null | wc -l)"
  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $description"
  fi
  after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'quill-provisioning.*' 2>/dev/null | wc -l)"
  [ ! -e "$out" ] || fail "output written after failure: $description"
  [ "$before" -eq "$after" ] || fail "temporary files left after failure: $description"
}

expect_failure "profile for another app" \
  entitlements "$profile" com.example.other Development iCloud.com.example.notes "$cert_b_hash" "$base" "$out"
expect_failure "container the profile does not allow" \
  entitlements "$profile" com.example.notes.dev Development iCloud.com.example.other "$cert_b_hash" "$base" "$out"
expect_failure "signing identity the profile does not list" \
  entitlements "$profile" com.example.notes.dev Development iCloud.com.example.notes "$other_hash" "$base" "$out"
FAKE_UDID="00000000-SYNTHETIC-UNREGISTERED" expect_failure "Mac not registered in the profile" \
  entitlements "$profile" com.example.notes.dev Development iCloud.com.example.notes "$cert_b_hash" "$base" "$out"

documents_only="$temporary_dir/documents.provisionprofile"
write_profile "$documents_only" "TEAMID1234.com.example.notes.dev" "Development" "2099-01-01T00:00:00Z" "$this_mac" "CloudDocuments"
expect_failure "profile without CloudKit" \
  entitlements "$documents_only" com.example.notes.dev Development iCloud.com.example.notes "$cert_b_hash" "$base" "$out"

# A Developer ID profile lists no devices and allows only Production.
production_only="$temporary_dir/production.provisionprofile"
write_profile "$production_only" "TEAMID1234.com.example.notes" "Production" "2099-01-01T00:00:00Z" ""
expect_failure "Development on a Production-only profile" \
  entitlements "$production_only" com.example.notes Development iCloud.com.example.notes "$cert_a_hash" "$base" "$out"
FAKE_UDID="00000000-SYNTHETIC-UNREGISTERED" \
  entitlements "$production_only" com.example.notes Production iCloud.com.example.notes "$cert_a_hash" "$base" "$out"
[ "$(read_key com.apple.developer.icloud-container-environment)" = "Production" ] || fail "production environment"

expired="$temporary_dir/expired.provisionprofile"
write_profile "$expired" "TEAMID1234.com.example.notes" "Production" "2001-01-01T00:00:00Z" ""
expect_failure "expired profile" \
  entitlements "$expired" com.example.notes Production iCloud.com.example.notes "$cert_a_hash" "$base" "$out"

expect_failure "missing profile" \
  entitlements "$temporary_dir/missing.provisionprofile" com.example.notes Production iCloud.com.example.notes "$cert_a_hash" "$base" "$out"

# The signing identity is the keychain identity whose certificate the
# profile lists.
[ "$(bash "$script" identity "$profile")" = "$cert_b_hash" ] || fail "identity selection"
FAKE_IDENTITIES="  1) $other_hash \"Developer ID Application: Synthetic\"" expect_failure "no matching identity" \
  bash "$script" identity "$profile"

echo "ProvisioningSigningTests passed"
