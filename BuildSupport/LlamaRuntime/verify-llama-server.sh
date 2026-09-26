#!/usr/bin/env bash
set -euo pipefail

helper="${1:?helper path required}"
expected_arch="${2:?expected architecture required}"

fail() {
  printf 'Local AI server verification failed: %s\n' "$1" >&2
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
  if grep -E '(@rpath/)?lib(llama|ggml)' <<<"$linked_libraries" >/dev/null; then
    fail "helper links dynamic llama.cpp/ggml libraries for $required_arch"
  fi
  # Only macOS system libraries exist on every user's Mac.
  non_system_libraries="$(tail -n +2 <<<"$linked_libraries" \
    | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
  if [ -n "$non_system_libraries" ]; then
    fail "helper links a non-system library for $required_arch: $(tr '\n' ' ' <<<"$non_system_libraries")"
  fi

  symbols="$(nm -arch "$required_arch" -gU "$helper")"
  # Older ggml exports ggml_metallib_start/end; newer ggml embeds one
  # library per kernel module (ggml_metallib_<module>_start/end).
  for pattern in 'ggml_metallib(_[a-z0-9_]+)?_start' 'ggml_metallib(_[a-z0-9_]+)?_end'; do
    grep -Eq "_${pattern}\$" <<<"$symbols" \
      || fail "missing embedded Metal kernel symbol ${pattern} for $required_arch"
  done
done

printf 'Verified Local AI server helper: %s (%s)\n' \
  "$helper" "$helper_archs"
