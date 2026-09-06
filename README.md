# NDI Viewer for Apple TV

A minimal tvOS app that discovers NDI video sources on the local network and
plays one full-screen. Built as a free alternative to the paid NDI monitor
apps on the App Store — you build and sideload it yourself instead of buying
a license.

## What's here

- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. The
  `.xcodeproj` isn't committed; you generate it locally so there's nothing to
  merge-conflict on.
- `Sources/NDIViewerTV/`
  - `NDIReceiver.swift` — wraps the NDI C SDK: source discovery
    (`NDIlib_find_*`) and video receive (`NDIlib_recv_*`), converting each
    incoming frame into a `CMSampleBuffer` with no memcpy (the NDI frame's
    lifetime is tied to the `CVPixelBuffer` via a release callback).
  - `VideoDisplayView.swift` — `AVSampleBufferDisplayLayer` wrapped for
    SwiftUI, fed by the receiver.
  - `ContentView.swift` — source picker → full-screen playback, Menu button
    on the remote (`onExitCommand`) disconnects back to the list.
  - `Bridging/NDIViewerTV-Bridging-Header.h` — imports the NDI SDK's C header
    into Swift.

Audio isn't wired up yet — video only.

## Setup (do this on your Mac)

1. **Get the NDI SDK.** Register (free) and download the NDI Advanced SDK
   for Apple platforms from https://ndi.video/for-developers/ndi-sdk/
2. **Drop the SDK into `Vendor/NDI/`** — see `Vendor/NDI/README.md` for the
   expected layout. This is the one step I couldn't do for you or verify,
   since the download is login-gated and NDI has renamed the packaged
   framework across SDK releases. If `project.yml`'s dependency path doesn't
   match what you actually got, edit that one path.
3. **Install XcodeGen** if you don't have it: `brew install xcodegen`
4. **Generate the Xcode project:**
   ```
   xcodegen generate
   ```
5. **Open `NDIViewerTV.xcodeproj`** in Xcode. Under the target's *Signing &
   Capabilities*, set your Team — a free Apple ID works fine here (shows up
   as "Personal Team").
6. **Run to your Apple TV.** Same network as your Mac, select it as the run
   destination, hit Run. tvOS will prompt for local network access the first
   time — accept it, or discovery won't find anything.

## The free-account catch

Signing with a free Apple ID (no paid Developer Program) means the app's
provisioning expires after **7 days**. To keep it working, reconnect to your
Mac and hit Run again in Xcode roughly once a week — no need to change
anything, just rebuild. Paying $99/year for the Developer Program removes
this limit entirely if the weekly rebuild gets old.

## Known rough edges (first draft, untested — I have no Mac to build this on)

- The exact NDI SDK struct/field names (`p_url_address` vs `p_ip_address`,
  capture function version) can drift slightly between SDK releases. If
  Xcode throws unknown-member errors in `NDIReceiver.swift`, check the field
  names in the `Processing.NDI.Lib.h` you actually got against what's used
  there — should be a quick fix.
- No audio playback.
- No handling yet for a source going offline mid-playback (the capture loop
  will just idle rather than surfacing an error to the UI).
- Only tested to compile mentally, not in Xcode — expect at least one round
  of build-error fixes on first try.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
