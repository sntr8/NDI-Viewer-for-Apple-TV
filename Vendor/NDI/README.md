# NDI SDK goes here

Not included in this repo — it's a proprietary download from NDI, tied to a
free registration.

1. Get the "NDI Advanced SDK" (Apple platforms) from https://ndi.video/for-developers/ndi-sdk/
2. Find the tvOS `.xcframework` inside the download and copy it here, e.g.:
   `Vendor/NDI/libndi_advanced.xcframework`
3. Find the `Processing.NDI.Lib.h` header inside the download and copy the
   folder containing it here as `Vendor/NDI/include/`.

If the filenames you get don't match `libndi_advanced.xcframework`, either
rename what you got to match, or edit the path in `project.yml` under
`targets.NDIViewerTV.dependencies` to match what NDI actually shipped —
they've renamed this file across SDK versions, so this couldn't be nailed
down without downloading it (login-gated).
