#!/usr/bin/env bash
set -euo pipefail

repo_url="${1:?repo url required}"
version="${2:?version required}"
checkout_dir="${3:?checkout dir required}"

mkdir -p "$(dirname "$checkout_dir")"

if [ ! -d "$checkout_dir/.git" ]; then
  git clone --depth 1 --branch "$version" "$repo_url" "$checkout_dir"
else
  git -C "$checkout_dir" fetch --depth 1 origin "refs/tags/$version:refs/tags/$version"
  git -C "$checkout_dir" checkout --force "$version"
fi

cmake -S "$checkout_dir" -B "$checkout_dir/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$checkout_dir/build" --target whisper-cli --config Release -j "$(sysctl -n hw.ncpu)"

test -x "$checkout_dir/build/bin/whisper-cli"
