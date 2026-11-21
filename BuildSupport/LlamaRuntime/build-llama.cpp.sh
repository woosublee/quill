#!/usr/bin/env bash
set -euo pipefail

repo_url="${1:?repo url required}"
version="${2:?version required}"
checkout_dir="${3:?checkout dir required}"
arch="${4:-$(uname -m)}"
verify_script="$(cd "$(dirname "$0")" && pwd)/verify-llama-server.sh"

mkdir -p "$(dirname "$checkout_dir")"

if [ ! -d "$checkout_dir/.git" ]; then
  git clone --depth 1 --branch "$version" "$repo_url" "$checkout_dir"
else
  git -C "$checkout_dir" fetch --depth 1 origin "refs/tags/$version:refs/tags/$version"
  git -C "$checkout_dir" checkout --force "$version"
fi

license="$checkout_dir/LICENSE"
if [ ! -s "$license" ]; then
  echo "Missing or empty llama.cpp LICENSE at $license" >&2
  exit 1
fi

# Build one architecture per build tree. ggml only enables its NEON or AVX CPU
# kernels when CMAKE_OSX_ARCHITECTURES names a single architecture; a combined
# "arm64;x86_64" build falls back to generic CPU code in both slices.
build_arch() {
  local build_arch="$1"
  local build_dir="$2"
  # The deployment target keeps the helper launchable on the app's minimum
  # macOS instead of inheriting the build machine's SDK version.
  #
  # Quill never serves llama-server's web UI (it starts the server with
  # --no-webui), so the build neither builds nor downloads the UI's assets
  # (#867): a failed download used to break every build. UI assets left in
  # the source tree or by an earlier build are removed first, since
  # llama.cpp embeds whatever it finds there.
  rm -rf "$checkout_dir/tools/ui/dist" "$build_dir/tools/ui/dist" \
    "$build_dir/tools/ui/dist.tar.gz" "$build_dir/tools/ui/dist.tar.gz.sha256" "$build_dir/tools/ui/ui-gzip"
  cmake -S "$checkout_dir" -B "$build_dir" \
    -DCMAKE_OSX_ARCHITECTURES="$build_arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON
  cmake --build "$build_dir" --target llama-server --config Release -j "$(sysctl -n hw.ncpu)"
  # A download would leave its assets here. Fail rather than ship them, for
  # example if a llama.cpp update renames the options above.
  if [ -e "$build_dir/tools/ui/dist" ] || [ -e "$build_dir/tools/ui/dist.tar.gz" ]; then
    echo "llama-server build fetched web UI assets; it should build without them (#867)" >&2
    exit 1
  fi
}

mkdir -p "$checkout_dir/build/bin"
if [ "$arch" = "universal" ]; then
  build_arch arm64 "$checkout_dir/build-arm64"
  build_arch x86_64 "$checkout_dir/build-x86_64"
  lipo -create \
    "$checkout_dir/build-arm64/bin/llama-server" \
    "$checkout_dir/build-x86_64/bin/llama-server" \
    -output "$checkout_dir/build/bin/llama-server"
else
  build_arch "$arch" "$checkout_dir/build-$arch"
  cp "$checkout_dir/build-$arch/bin/llama-server" "$checkout_dir/build/bin/llama-server"
fi

helper="$checkout_dir/build/bin/llama-server"
"$verify_script" "$helper" "$arch"
