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
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$checkout_dir/build" --target whisper-cli --config Release -j "$(sysctl -n hw.ncpu)"

helper="$checkout_dir/build/bin/whisper-cli"
"$verify_script" "$helper" "$arch"
