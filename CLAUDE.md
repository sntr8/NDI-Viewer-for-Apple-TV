# NDI Viewer for Apple TV — handoff notes

## What this is

A tvOS app that discovers NDI video sources on the LAN and plays one
full-screen, built to avoid paying for one of the existing App Store NDI
monitor apps (€50-100). The whole thing was scaffolded by a Claude Code
instance running on a headless Linux server with **no Mac, no Xcode, and no
way to compile or run any of this** — so treat the current state as an
unverified first draft, not working code. You (running with real Xcode
access) are the first person to actually build it.

## Current state

- `project.yml` — XcodeGen spec. No `.xcodeproj` is committed; generate it
  with `xcodegen generate` (install via `brew install xcodegen` if needed).
- `Sources/NDIViewerTV/`
  - `NDIReceiver.swift` — wraps the NDI C SDK: `NDIlib_find_*` for discovery,
    `NDIlib_recv_*` for video receive. Converts each NDI frame to a
    `CVPixelBuffer` with **no memcpy** — the frame's lifetime is tied to the
    pixel buffer via a `CVPixelBufferCreateWithBytes` release callback
    (see `NDIFrameOwner`), then wrapped into a `CMSampleBuffer`.
  - `VideoDisplayView.swift` — `AVSampleBufferDisplayLayer` in a
    `UIViewRepresentable`, fed by the receiver's `onVideoSampleBuffer`
    callback.
  - `ContentView.swift` — source list → full-screen playback; Menu button
    (`onExitCommand`) disconnects back to the list.
  - `NDIViewerTVApp.swift` — trivial `@main` entry point.
- Audio is not implemented — video only.
- The NDI SDK itself is **not** in the repo (proprietary, login-gated
  download). `Vendor/NDI/README.md` explains what needs to go there.

## Do this first

1. Register (free) and download the NDI Advanced SDK for Apple platforms:
   https://ndi.video/for-developers/ndi-sdk/
2. Drop it into `Vendor/NDI/` per `Vendor/NDI/README.md`.
3. **Open `Processing.NDI.Lib.h` from the SDK and check these against what's
   actually in `NDIReceiver.swift`** — the origin Claude instance could not
   verify the exact struct layout of the current SDK release, and NDI has
   shifted field names across versions:
   - `NDIlib_source_t` — code assumes `p_ndi_name` and `p_url_address`.
     Some SDK versions use `p_ip_address` instead of/alongside
     `p_url_address`.
   - The capture call — code uses `NDIlib_recv_capture_v2`. Confirm that's
     still the right pairing with `NDIlib_recv_create_v3`.
   - `p_data`'s exact pointer type on `NDIlib_video_frame_v2_t` (affects the
     `UnsafeMutableRawPointer(data)` cast in `handleVideoFrame`).
   - Whether the SDK gives you a `.xcframework` (current expectation, wired
     into `project.yml`'s `dependencies:`) or an older static `.a` lib
     (there's a commented-out alternative linking block in `project.yml` for
     that case).
4. `xcodegen generate`, open `NDIViewerTV.xcodeproj`, set your Team under
   Signing & Capabilities (a free "Personal Team" is fine — see the free
   Apple ID / 7-day provisioning note in the main README), run to the Apple
   TV.

## What to expect on first build

Almost certainly a handful of compile errors from the SDK version
mismatches above — this whole file exists because those couldn't be checked
without the SDK in hand. Fix them by matching the actual header, not by
guessing further. Once it compiles, the things most likely to be visibly
wrong on the TV screen (not compile errors, but behavior):

- Blank/black screen despite a source connecting → check `color_format` is
  actually giving BGRA/BGRX and that `line_stride_in_bytes` matches what
  `CVPixelBufferCreateWithBytes` expects (padding vs tight rows).
- No sources found at all → check the Local Network permission prompt was
  accepted, and that `NSBonjourServices`/`NSLocalNetworkUsageDescription` in
  `project.yml`'s `info.properties` are actually landing in the built
  Info.plist (`Generated/Info.plist` after `xcodegen generate`).
- Stutter/tearing → likely a timing issue in the `CMSampleTimingInfo` built
  from `CMClockGetHostTimeClock()`; may need real presentation timestamps
  derived from the NDI frame's own timecode instead.

## Working conventions for this repo

- Keep `project.yml` as the source of truth — don't hand-edit the generated
  `.xcodeproj`'s settings; add them to `project.yml` and regenerate.
- The NDI SDK files under `Vendor/NDI/` are gitignored on purpose (license
  terms) — never commit them even if Xcode drags them in.
- No CI/test suite exists yet; verification is "does it actually show video
  on the TV," so changes to `NDIReceiver.swift` or `VideoDisplayView.swift`
  should be checked by running on hardware, not just by compiling.
