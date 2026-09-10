# NDI Viewer for Apple TV

A minimal tvOS app that lists the NDI sources on your local network and plays
one full-screen, with audio. Built as a free alternative to the paid NDI
monitor apps on the App Store — you build and sideload it yourself instead of
buying a license.

That's the whole app: a list, a refresh button, and full-screen playback.
Press Menu to go back to the list.

## Setup

```
Tools/install-ndi-sdk.sh     # downloads the NDI SDK, stages Vendor/NDI/
brew install xcodegen        # if you don't have it
xcodegen generate
open NDIViewerTV.xcodeproj
```

Then set your Team under the target's *Signing & Capabilities* — a free Apple
ID works, it shows up as "Personal Team" — pick your Apple TV as the run
destination and hit Run. tvOS prompts for local network access the first time;
accept it, or discovery finds nothing.

**It has to be real hardware.** The NDI SDK's only tvOS simulator slice is
x86_64, so there's no simulator build on an Apple silicon Mac.

Xcode also needs the tvOS platform component installed (Settings > Components)
— without it `actool` can't compile the app icon and the Apple TV won't show up
as a run destination.

## The free-account catch

Signing with a free Apple ID (no paid Developer Program) means provisioning
expires after **7 days**. Reconnect to your Mac and hit Run again roughly once
a week — nothing to change, just rebuild. The $99/year Developer Program
removes the limit.

## How it works

- `Sources/NDIViewerTV/NDIReceiver.swift` — wraps the NDI C SDK. Discovery via
  `NDIlib_find_*`; `NDIlib_recv_capture_v3` pulls video and audio off one
  receiver. Video frames are copied into a pooled IOSurface-backed
  `CVPixelBuffer` (`AVSampleBufferDisplayLayer` won't reliably render anything
  else), audio is de-planarized to interleaved float. Both come out as
  `CMSampleBuffer`s stamped against NDI's own sender clock.
- `Sources/NDIViewerTV/NDIPlayer.swift` — an `AVSampleBufferRenderSynchronizer`
  driving a display layer and an `AVSampleBufferAudioRenderer`. Since NDI stamps
  video and audio from one clock, one synchronizer over both is what keeps them
  in sync; it holds the clock until 0.2s is queued so the first hiccup doesn't
  underrun.
- `Sources/NDIViewerTV/ContentView.swift` — the source list and full-screen
  playback.
- `Tools/make-brand-assets.swift` — regenerates the tvOS app icon and top shelf
  art from `Tools/ndiplayer.png`.

## Known limits

- No handling for a source going offline mid-playback beyond surfacing the
  error — no automatic reconnect.
- Video is received as BGRA. Anything else from a source (e.g. a compressed
  format) is reported rather than rendered.
- Not tested beyond 1080p.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
