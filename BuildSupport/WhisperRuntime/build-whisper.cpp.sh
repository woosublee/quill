#!/usr/bin/env bash
set -euo pipefail

repo_url="${1:?repo url required}"
version="${2:?version required}"
checkout_dir="${3:?checkout dir required}"
arch="${4:-$(uname -m)}"

mkdir -p "$(dirname "$checkout_dir")"

if [ ! -d "$checkout_dir/.git" ]; then
  git clone --depth 1 --branch "$version" "$repo_url" "$checkout_dir"
else
  git -C "$checkout_dir" fetch --depth 1 origin "refs/tags/$version:refs/tags/$version"
  git -C "$checkout_dir" checkout --force "$version"
fi

cmake_arch_args=()
if [ "$arch" = "universal" ]; then
  cmake_arch_args=(-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64")
else
  cmake_arch_args=(-DCMAKE_OSX_ARCHITECTURES="$arch")
fi

cmake -S "$checkout_dir" -B "$checkout_dir/build" \
  "${cmake_arch_args[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$checkout_dir/build" --target whisper-cli --config Release -j "$(sysctl -n hw.ncpu)"

helper="$checkout_dir/build/bin/whisper-cli"
test -x "$helper"

if otool -L "$helper" | grep -E '(@rpath/)?lib(whisper|ggml)' >/dev/null; then
  echo "whisper-cli still links whisper.cpp/ggml dylibs; expected a self-contained helper." >&2
  otool -L "$helper" >&2
  exit 1
fi

helper_archs="$(lipo -archs "$helper")"
if [ "$arch" = "universal" ]; then
  for required_arch in arm64 x86_64; do
    case " $helper_archs " in
      *" $required_arch "*) ;;
      *)
        echo "whisper-cli is not universal; missing $required_arch; found architectures: $helper_archs" >&2
        exit 1
        ;;
    esac
  done
else
  case " $helper_archs " in
    *" $arch "*) ;;
    *)
      echo "whisper-cli missing requested architecture $arch; found architectures: $helper_archs" >&2
      exit 1
      ;;
  esac
fi
