#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
destination="$repo/Packages/TranslationRuntime/llama.xcframework"
revision=401563f10ec60754e688cd3165c1343cf4be9642

if [[ -f "$destination/Info.plist" ]]; then
    exit 0
fi

working="$(mktemp -d /tmp/pdfvocab-llama.XXXXXXXX)"
trap 'rm -rf "$working"' EXIT
git -C "$working" init -q
git -C "$working" fetch --depth 1 https://github.com/ggml-org/llama.cpp.git "$revision"
git -C "$working" checkout --detach "$revision"
test "$(git -C "$working" rev-parse HEAD)" = "$revision"
(cd "$working" && bash ./build-xcframework.sh ios-sim ios-device)
test -f "$working/build-apple/llama.xcframework/Info.plist"
ditto "$working/build-apple/llama.xcframework" "$destination"
