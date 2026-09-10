#!/bin/bash
# Downloads the NDI SDK for Apple and stages it into Vendor/NDI/.
#
# The SDK ships a fat static library (lib/tvOS/libndi_tvos.a) rather than an
# xcframework, so this also splits the device and simulator slices back apart
# and packages them as one — which is what project.yml links against.
#
# Vendor/NDI/ is gitignored: the SDK is NVIDIA's to license, not ours to
# redistribute. Re-run this after a fresh clone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$REPO_ROOT/Vendor/NDI"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

URL="https://downloads.ndi.tv/SDK/NDI_SDK_Mac/Install_NDI_SDK_v6_Apple.pkg"

echo "==> Downloading the NDI SDK for Apple"
curl -# -L -o "$WORK/ndi.pkg" "$URL"

echo "==> Unpacking"
pkgutil --expand "$WORK/ndi.pkg" "$WORK/pkg"
mkdir -p "$WORK/payload"
(cd "$WORK/payload" && gunzip -dc "$WORK/pkg/NDI_SDK_Component.pkg/Payload" | cpio -i --quiet)

SDK="$WORK/payload/NDI SDK for Apple"
[ -d "$SDK" ] || { echo "Unexpected payload layout under $WORK/payload" >&2; exit 1; }

echo "==> Building libndi_tvos.xcframework"
mkdir -p "$WORK/device" "$WORK/sim"
lipo -thin arm64  -output "$WORK/device/libndi_tvos.a" "$SDK/lib/tvOS/libndi_tvos.a"
lipo -thin x86_64 -output "$WORK/sim/libndi_tvos.a"    "$SDK/lib/tvOS/libndi_tvos.a"

rm -rf "$VENDOR/libndi_tvos.xcframework" "$VENDOR/include" "$VENDOR/licenses"
mkdir -p "$VENDOR"
xcodebuild -create-xcframework \
  -library "$WORK/device/libndi_tvos.a" -headers "$SDK/include" \
  -library "$WORK/sim/libndi_tvos.a"    -headers "$SDK/include" \
  -output "$VENDOR/libndi_tvos.xcframework" >/dev/null

cp -R "$SDK/include" "$VENDOR/include"
cp -R "$SDK/licenses" "$VENDOR/licenses"

echo "==> Done — $VENDOR now has:"
ls -1 "$VENDOR"
echo
echo "Next: xcodegen generate && open NDIViewerTV.xcodeproj"
