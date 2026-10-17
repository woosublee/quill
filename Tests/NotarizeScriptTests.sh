#!/usr/bin/env bash
set -euo pipefail

script="$PWD/scripts/notarize.sh"
temporary_dir="$(mktemp -d -t quill-notarize-test)"
trap 'rm -rf "$temporary_dir"' EXIT

fail() {
  echo "NotarizeScriptTests: $*" >&2
  exit 1
}

# A stand-in for xcrun, found first on PATH: it records each notarytool
# call and answers with $FAKE_STATUS. Nothing reaches Apple.
bin="$temporary_dir/bin"
calls="$temporary_dir/calls"
mkdir -p "$bin"
cat > "$bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
if [ "$1 $2" = "notarytool submit" ]; then
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>id</key><string>synthetic-id</string><key>status</key><string>%s</string></dict></plist>' "$FAKE_STATUS"
fi
exit 0
STUB
chmod +x "$bin/xcrun"
export PATH="$bin:$PATH" FAKE_CALLS="$calls"
artifact="$temporary_dir/Synthetic.zip"
: > "$artifact"

run() {
  : > "$calls"
  env "$@" bash "$script" "$artifact" >/dev/null 2>&1
}

# The release workflow: its temporary keychain and fixed profile name.
FAKE_STATUS=Accepted run -u NOTARIZE_PROFILE KEYCHAIN_PATH=/synthetic/release.keychain-db \
  || fail "an accepted CI submission should succeed"
grep -q -- "notarytool submit $artifact --keychain-profile notarytool-profile --keychain /synthetic/release.keychain-db --wait" "$calls" \
  || fail "CI submissions should use notarytool-profile in KEYCHAIN_PATH: $(cat "$calls")"

# Local: a profile in the login keychain, with no --keychain.
FAKE_STATUS=Accepted run -u KEYCHAIN_PATH NOTARIZE_PROFILE=synthetic-profile \
  || fail "an accepted local submission should succeed"
grep -q -- "notarytool submit $artifact --keychain-profile synthetic-profile --wait" "$calls" \
  || fail "local submissions should use NOTARIZE_PROFILE: $(cat "$calls")"
if grep -q -- "--keychain " "$calls"; then
  fail "local submissions should not name a keychain"
fi

# A rejection fails and fetches Apple's log with the same credentials.
if FAKE_STATUS=Invalid run -u KEYCHAIN_PATH NOTARIZE_PROFILE=synthetic-profile; then
  fail "a rejected submission should fail"
fi
grep -q -- "notarytool log synthetic-id --keychain-profile synthetic-profile" "$calls" \
  || fail "a rejected submission should print Apple's log: $(cat "$calls")"

# Still processing locally: the resume command names the profile, quoted,
# and Apple's log isn't fetched for an unfinished submission.
output="$temporary_dir/output"
: > "$calls"
if env -u KEYCHAIN_PATH FAKE_STATUS="In Progress" NOTARIZE_PROFILE="Synthetic Profile" \
  bash "$script" "$artifact" > "$output" 2>&1; then
  fail "an unfinished submission should fail"
fi
grep -q -- 'xcrun notarytool wait synthetic-id --keychain-profile Synthetic\\ Profile' "$output" \
  || fail "an unfinished local submission should print a resume command: $(cat "$output")"
if grep -q -- "notarytool log" "$calls"; then
  fail "an unfinished submission should not fetch Apple's log"
fi

# Both credentials: ambiguous, so fail before submitting anything.
if FAKE_STATUS=Accepted run KEYCHAIN_PATH=/synthetic/release.keychain-db NOTARIZE_PROFILE=synthetic-profile; then
  fail "a submission with both KEYCHAIN_PATH and NOTARIZE_PROFILE should fail"
fi
[ ! -s "$calls" ] || fail "nothing should be submitted with both credentials"

# Neither credential: fail before submitting anything.
if FAKE_STATUS=Accepted run -u KEYCHAIN_PATH -u NOTARIZE_PROFILE; then
  fail "a submission without credentials should fail"
fi
[ ! -s "$calls" ] || fail "nothing should be submitted without credentials"

# make notarize stops before building when no profile is given.
# Run without the outer make's settings or any notarization credentials.
make_output="$(env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS -u KEYCHAIN_PATH -u NOTARIZE_PROFILE \
  make --no-print-directory notarize NOTARIZE_PROFILE= BUILD_DIR="$temporary_dir/build" 2>&1)" \
  && fail "make notarize without NOTARIZE_PROFILE should fail"
case "$make_output" in
  *"Set NOTARIZE_PROFILE"*) ;;
  *) fail "make notarize should explain NOTARIZE_PROFILE: $make_output" ;;
esac
[ ! -e "$temporary_dir/build" ] || fail "make notarize should stop before building"

# ...and when the signing identity isn't a Developer ID Application one.
make_output="$(env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS -u KEYCHAIN_PATH -u NOTARIZE_PROFILE \
  make --no-print-directory notarize NOTARIZE_PROFILE=synthetic-profile \
  CODESIGN_IDENTITY=synthetic-missing-identity BUILD_DIR="$temporary_dir/build" 2>&1)" \
  && fail "make notarize without a Developer ID identity should fail"
case "$make_output" in
  *"needs a Developer ID Application identity"*) ;;
  *) fail "make notarize should explain the identity: $make_output" ;;
esac
[ ! -e "$temporary_dir/build" ] || fail "make notarize should stop before building"

echo "NotarizeScriptTests passed"
