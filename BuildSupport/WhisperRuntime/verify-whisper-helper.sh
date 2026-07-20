#!/usr/bin/env bash
set -euo pipefail

helper="${1:?helper path required}"
expected_arch="${2:?expected architecture required}"

fail() {
  printf 'Native Whisper helper verification failed: %s\n' "$1" >&2
  exit 1
}

[ -x "$helper" ] || fail "helper is missing or not executable: $helper"
[ "$(stat -f %z "$helper")" -gt 0 ] || fail "helper is empty: $helper"

helper_archs="$(lipo -archs "$helper")"
case "$expected_arch" in
  universal)
    required_archs=(arm64 x86_64)
    ;;
  arm64|x86_64)
    required_archs=("$expected_arch")
    ;;
  *)
    fail "unsupported expected architecture: $expected_arch"
    ;;
esac

for required_arch in "${required_archs[@]}"; do
  case " $helper_archs " in
    *" $required_arch "*) ;;
    *) fail "missing required architecture $required_arch; found: $helper_archs" ;;
  esac

  linked_libraries="$(otool -arch "$required_arch" -L "$helper")"
  grep -F 'Metal.framework' <<<"$linked_libraries" >/dev/null \
    || fail "missing Metal.framework linkage for $required_arch"
  grep -F 'MetalKit.framework' <<<"$linked_libraries" >/dev/null \
    || fail "missing MetalKit.framework linkage for $required_arch"
  if grep -E '(@rpath/)?lib(whisper|ggml)' <<<"$linked_libraries" >/dev/null; then
    fail "helper links dynamic whisper.cpp/ggml libraries for $required_arch"
  fi

  symbols="$(nm -arch "$required_arch" -gU "$helper")"
  for symbol in ggml_metallib_start ggml_metallib_end; do
    grep -F "$symbol" <<<"$symbols" >/dev/null \
      || fail "missing embedded Metal kernel symbol $symbol for $required_arch"
  done
done

printf 'Verified Native Whisper Metal helper: %s (%s)\n' \
  "$helper" "$helper_archs"
