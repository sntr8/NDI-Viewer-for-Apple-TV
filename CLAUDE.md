# NDI Viewer for Apple TV — working notes

## What this is

A tvOS app that lists NDI sources on the LAN and plays one full-screen with
audio, to avoid paying for an App Store NDI monitor app. Scope is deliberately
small: source list, refresh button, full-screen playback, Menu to go back.
Nothing else.

It was first scaffolded on a headless Linux box with no Mac and no SDK, so an
earlier version of this file was full of "verify this against the real header"
caveats. That's all been done — the notes below are what was actually found.

## Environment facts (verified, Sept 2026)

- **SDK**: "NDI SDK for Apple" **6.3.2**, from
  `https://downloads.ndi.tv/SDK/NDI_SDK_Mac/Install_NDI_SDK_v6_Apple.pkg`.
  That URL downloads without a login; the *Advanced* SDK's does not, and isn't
  needed. `Tools/install-ndi-sdk.sh` does the whole download-and-stage.
- It ships **`lib/tvOS/libndi_tvos.a`**, a fat static lib — *not* an
  xcframework. arm64 slice is tvOS device (platform 3), x86_64 is tvOS
  simulator (platform 8). The install script splits and repacks them into
  `Vendor/NDI/libndi_tvos.xcframework`.
- **No arm64 simulator slice**, so there is no simulator build on Apple
  silicon. Verification means running on the actual Apple TV.
- The static lib needs **VideoToolbox** (H.264 encode/decode) and
  **Accelerate** (vImage colour conversion) linked explicitly, plus `-lc++`
  since a Swift-only target won't pull in the C++ runtime. All three are in
  `project.yml`; without them you get a wall of undefined symbols out of
  `video_codec_interface.o` and `format_conversion_main.o`.
- Swift imports the C headers cleanly, anonymous unions included:
  `p_ndi_name`, `p_url_address`, `line_stride_in_bytes` and
  `channel_stride_in_bytes` are all directly accessible. No shims needed.

## Xcode gotcha

Building needs the **tvOS platform component** installed (Xcode > Settings >
Components), not just the tvOS SDK that ships inside Xcode.app. Without it:

- `actool` fails with "No available simulator runtimes for platform
  appletvsimulator" whenever the asset catalog is compiled, and
- `-destination generic/platform=tvOS` intermittently resolves to "tvOS 26.5 is
  not installed", so the Apple TV won't appear as a run destination.

Swift compile and link work fine without it, so `EXCLUDED_SOURCE_FILE_NAMES=
Assets.xcassets` plus `-target` (rather than `-scheme`) is a usable way to
sanity-check a build if the component is missing.

## Architecture

- `NDIReceiver` — one serial queue owns the find instance, another owns the
  recv instance. connect/disconnect only ever *enqueue* work onto the capture
  queue, so a blocking `NDIlib_recv_capture_v3` never has its instance
  destroyed underneath it. Cross-thread booleans live in `StateFlags`.
- Video is **copied** into a pooled IOSurface-backed `CVPixelBuffer`. The
  original draft wrapped NDI's own memory with `CVPixelBufferCreateWithBytes`
  to avoid a memcpy, but `AVSampleBufferDisplayLayer` only reliably renders
  IOSurface-backed buffers — that zero-copy path is the classic cause of a
  black screen with a connected source. Don't reintroduce it.
- Audio is de-planarized with `NDIlib_util_audio_to_interleaved_32f_v3`
  straight into the `CMBlockBuffer`'s own allocation, so nothing is freed by
  hand.
- A/V sync comes from a single `AVSampleBufferRenderSynchronizer` fed by both
  renderers, with presentation timestamps taken from NDI's `timestamp` field
  (100ns, sender clock, shared between video and audio) rebased to zero at the
  first frame. Don't give audio and video separate clocks.

## The audio timeline — measured behaviour, and an open bug

All numbers below come from runs against the "ODYSSEY (Game Feed)" source on
2026-09-10/11, logged off the device. Read this before touching `NDIPlayer`
or `audioPresentationTime`.

**Settled: NDI timestamps are not a sample clock.** `timestamp` marks when the
sender *submitted* the frame and carries its scheduling jitter — measured at
±40 to ±105 samples per buffer, mean ≈ 0. Stamping audio with it directly puts
a gap or overlap under every buffer and the renderer clicks on each seam. That
was the original "crackling" report. Audio is now clocked by counting samples
from an anchor, which fixed it. Don't undo this.

**Settled: sender and Apple TV clocks differ by ~22 ppm.** Over a 127-minute
run the queue drained 403ms → 236ms, a clean linear −21.8 ppm. Left alone this
underruns in ~3.6h and then repeats every ~5.7h. A fixed rate of 1.0 is
therefore not viable for long sessions.

**Settled: a timeline discontinuity is unrecoverable without help.** One run
saw a single −3826ms step (sender clock stepping, probably NTP or a restart);
every subsequent buffer arrived late and was discarded, giving permanent
silence. Hence the depth watchdog in `NDIPlayer` that flushes and rebuilds.
**This path has never actually fired in testing** — it is written but unproven.

**OPEN BUG: the rate servo never converges.** With the servo targeting 250ms,
depth instead sits in a sawtooth between ~500 and ~582ms on a ~160s period,
with the rate pegged at its +500 ppm clamp for the entire run. Something
refills the queue by ~80ms every ~160s and the servo cannot win against it.
Net effect: latency roughly doubled, ~540ms instead of the 250ms target.

The leading hypothesis — *unconfirmed* — is `audioPresentationTime`'s
re-anchor: 160s of a ~600 ppm sender sample-rate error would cross the 100ms
threshold and snap the audio timeline forward by about the observed amount. If
that's right, the hard snap is the wrong mechanism and the divergence should be
absorbed continuously (or the anchor tracked with a slow low-pass) rather than
reset in one jump.

The build in the working tree adds `re-anchor by ±Xms` and `stream gap X.XXs`
logging specifically to confirm or kill that hypothesis. **Next session: run
it, read those two lines, and fix the mechanism rather than tuning constants.**
A sender restart also still needs testing — the one attempt was inconclusive
because depth only logged every 10s and hid the interruption.

## Conventions

- `project.yml` is the source of truth. Don't hand-edit the generated
  `.xcodeproj`; change the spec and re-run `xcodegen generate`.
- `Vendor/NDI/` is gitignored on purpose (license terms). Never commit it, even
  if Xcode drags it in.
- App icon and top shelf art are generated — edit `Tools/ndiplayer.png` and
  re-run `swift Tools/make-brand-assets.swift`, don't hand-edit the catalog.
  tvOS image stacks need at least two layers, hence the split into a solid
  background and the logo tile.
- No CI or tests. Verification is "does it show video and stay in sync on the
  TV", so changes to the receiver or player need a run on hardware.
