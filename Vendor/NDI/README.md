# NDI SDK goes here

Not in the repo — it's NVIDIA's to license, and this directory is gitignored
apart from this file.

Run `Tools/install-ndi-sdk.sh` from the repo root and it will fill this in.
Afterwards you should have:

```
Vendor/NDI/include/                    Processing.NDI.*.h
Vendor/NDI/libndi_tvos.xcframework/    tvos-arm64 + tvos-x86_64-simulator
Vendor/NDI/licenses/
```

## What the script is working around

The "NDI SDK for Apple" download ships `lib/tvOS/libndi_tvos.a` — a *fat static
library*, not an xcframework, with an arm64 (device) slice and an x86_64
(simulator) slice in the one file. Xcode won't link that directly on Apple
silicon, so the script splits the slices and repacks them with
`xcodebuild -create-xcframework`.

Because the only simulator slice is x86_64, **there is no tvOS simulator build
on an Apple silicon Mac.** Run on real Apple TV hardware.

Verified against **NDI SDK for Apple 6.3.2** (April 2026).
