#!/usr/bin/env swift
// Regenerates Sources/NDIViewerTV/Assets.xcassets from Tools/ndiplayer.png.
//
// tvOS wants landscape brand assets (layered app icon + top shelf art) while
// the source logo is square, so each output is the logo scaled to fit and
// centred on the logo's own background colour — which makes the artwork's
// rounded corners disappear into the fill.
//
// Run from the repo root:  swift Tools/make-brand-assets.swift

import AppKit
import CoreGraphics
import Foundation

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = repoRoot.appendingPathComponent("Tools/ndiplayer.png")
let catalogURL = repoRoot.appendingPathComponent("Sources/NDIViewerTV/Assets.xcassets")

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let source = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Could not read \(sourceURL.path)")
}

/// Samples the artwork's background from a point inside its rounded rect but
/// clear of the white lettering.
func backgroundColor(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
    var pixel: [UInt8] = [0, 0, 0, 0]
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Nearest-neighbour, or the downscale averages in the transparent corners
    // and reports a colour darker than the artwork actually is.
    context.interpolationQuality = .none
    let x = CGFloat(image.width) * 0.12
    let y = CGFloat(image.height) * 0.50
    context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
    return (pixel[0], pixel[1], pixel[2])
}

let fill = backgroundColor(of: source)
print(String(format: "background #%02X%02X%02X", fill.r, fill.g, fill.b))

func render(width: CGFloat, height: CGFloat, logoHeightFraction: CGFloat, fillOnly: Bool = false, transparent: Bool = false, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    )!
    if !transparent {
        context.setFillColor(
            red: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255,
            blue: CGFloat(fill.b) / 255, alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    if !fillOnly {
        let side = (height * logoHeightFraction).rounded()
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: ((width - side) / 2).rounded(),
            y: ((height - side) / 2).rounded(),
            width: side, height: side
        ))
    }

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let fm = FileManager.default
try? fm.removeItem(at: catalogURL)

func write(_ json: String, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: url, atomically: true, encoding: .utf8)
}

let catalogInfo = """
{
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try write(catalogInfo, to: catalogURL.appendingPathComponent("Contents.json"))

/// An imageset holding one 1x/2x pair.
func makeImageSet(at url: URL, base: String, width: CGFloat, height: CGFloat, logoHeightFraction: CGFloat,
                  fillOnly: Bool = false, transparent: Bool = false) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    try render(width: width, height: height, logoHeightFraction: logoHeightFraction,
               fillOnly: fillOnly, transparent: transparent,
               to: url.appendingPathComponent("\(base).png"))
    try render(width: width * 2, height: height * 2, logoHeightFraction: logoHeightFraction,
               fillOnly: fillOnly, transparent: transparent,
               to: url.appendingPathComponent("\(base)@2x.png"))
    let contents = """
    {
      "images" : [
        { "filename" : "\(base).png", "idiom" : "tv", "scale" : "1x" },
        { "filename" : "\(base)@2x.png", "idiom" : "tv", "scale" : "2x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try write(contents, to: url.appendingPathComponent("Contents.json"))
}

/// tvOS app icons are parallax image stacks and actool insists on at least two
/// layers, so the flat artwork is split into a solid background and the logo
/// tile floating above it. Both share the same navy, which is what keeps the
/// tile's edges invisible while the layers slide against each other under focus.
func makeImageStack(at url: URL, base: String, width: CGFloat, height: CGFloat) throws {
    func layer(_ name: String, base: String, fillOnly: Bool, transparent: Bool) throws -> String {
        let layerURL = url.appendingPathComponent("\(name).imagestacklayer")
        try makeImageSet(at: layerURL.appendingPathComponent("Content.imageset"),
                         base: base, width: width, height: height, logoHeightFraction: 0.82,
                         fillOnly: fillOnly, transparent: transparent)
        try write("""
        {
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """, to: layerURL.appendingPathComponent("Contents.json"))
        return "\(name).imagestacklayer"
    }

    let front = try layer("Front", base: "\(base)-front", fillOnly: false, transparent: true)
    let back = try layer("Back", base: "\(base)-back", fillOnly: true, transparent: false)
    try write("""
    {
      "layers" : [ { "filename" : "\(front)" }, { "filename" : "\(back)" } ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """, to: url.appendingPathComponent("Contents.json"))
}

let brand = catalogURL.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
try fm.createDirectory(at: brand, withIntermediateDirectories: true)
try write("""
{
  "assets" : [
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", to: brand.appendingPathComponent("Contents.json"))

try makeImageStack(at: brand.appendingPathComponent("App Icon.imagestack"),
                   base: "icon", width: 400, height: 240)
try makeImageStack(at: brand.appendingPathComponent("App Icon - App Store.imagestack"),
                   base: "icon-store", width: 1280, height: 768)
try makeImageSet(at: brand.appendingPathComponent("Top Shelf Image.imageset"),
                 base: "top-shelf", width: 1920, height: 720, logoHeightFraction: 0.62)
try makeImageSet(at: brand.appendingPathComponent("Top Shelf Image Wide.imageset"),
                 base: "top-shelf-wide", width: 2320, height: 720, logoHeightFraction: 0.62)

print("wrote \(catalogURL.path)")
