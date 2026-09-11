# NDI Viewer for Apple TV

A tvOS app that finds NDI video sources on your local network and plays one
full-screen, with audio.

It exists because the NDI monitor apps on the App Store cost 50 to 100 euros.
This does the same job for free: you build it and sideload it yourself
instead of buying a license. The app is deliberately basic: a source list,
a refresh button, full-screen playback, Menu on the remote to go back.

## Build

```
Tools/install-ndi-sdk.sh     # downloads the NDI SDK, stages Vendor/NDI/
brew install xcodegen        # if you don't have it
xcodegen generate
open NDIViewerTV.xcodeproj
```

In Xcode, set your Team under the target's Signing & Capabilities. A free
Apple ID works fine, it shows up as "Personal Team".

Xcode also needs the tvOS platform component installed (Xcode > Settings >
Components). Without it, the app icon won't compile and the Apple TV won't
show up as a run destination.

## Deploy to Apple TV

Pick your Apple TV as the run destination and hit Run. The TV will prompt
for local network access on first launch — accept it, or the app won't find
any sources.

This has to run on real hardware: the NDI SDK's only tvOS simulator slice is
x86_64, so there's no simulator build on Apple silicon Macs.

With a free Apple ID (no paid Developer Program), the install expires after
7 days. Reconnect the Apple TV to your Mac and hit Run again in Xcode to
renew it — no changes needed, just a rebuild. Paying $99/year for the
Developer Program removes this limit.
