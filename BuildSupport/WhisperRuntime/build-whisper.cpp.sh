#!/usr/bin/env bash
set -euo pipefail

repo_url="${1:?repo url required}"
version="${2:?version required}"
checkout_dir="${3:?checkout dir required}"
arch="${4:-$(uname -m)}"
verify_script="$(cd "$(dirname "$0")" && pwd)/verify-whisper-helper.sh"

mkdir -p "$(dirname "$checkout_dir")"

if [ ! -d "$checkout_dir/.git" ]; then
  git clone --depth 1 --branch "$version" "$repo_url" "$checkout_dir"
else
  git -C "$checkout_dir" fetch --depth 1 origin "refs/tags/$version:refs/tags/$version"
  git -C "$checkout_dir" checkout --force "$version"
fi

# Build one architecture per build tree. ggml only enables its NEON or AVX CPU
# kernels when CMAKE_OSX_ARCHITECTURES names a single architecture; a combined
# "arm64;x86_64" build falls back to generic CPU code in both slices.
build_arch() {
  local build_arch="$1"
  local build_dir="$2"
  # The deployment target keeps the helper launchable on the app's minimum
  # macOS instead of inheriting the build machine's SDK version.
  cmake -S "$checkout_dir" -B "$build_dir" \
    -DCMAKE_OSX_ARCHITECTURES="$build_arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON
  cmake --build "$build_dir" --target whisper-cli --config Release -j "$(sysctl -n hw.ncpu)"
}

mkdir -p "$checkout_dir/build/bin"
if [ "$arch" = "universal" ]; then
  build_arch arm64 "$checkout_dir/build-arm64"
  build_arch x86_64 "$checkout_dir/build-x86_64"
  lipo -create \
    "$checkout_dir/build-arm64/bin/whisper-cli" \
    "$checkout_dir/build-x86_64/bin/whisper-cli" \
    -output "$checkout_dir/build/bin/whisper-cli"
else
  build_arch "$arch" "$checkout_dir/build-$arch"
  cp "$checkout_dir/build-$arch/bin/whisper-cli" "$checkout_dir/build/bin/whisper-cli"
fi

helper="$checkout_dir/build/bin/whisper-cli"
"$verify_script" "$helper" "$arch"
