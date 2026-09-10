#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Generates Resources/AppIcon.icns and Resources/Icon/icon-1024.png.
///
/// Design (Apple macOS 11+ app-icon template):
///   1024×1024 canvas, ~100px transparent margin, 824×824 centred squircle,
///   corner radius ≈ 22.37% of the shape, amber → orange vertical gradient,
///   white `sun.max.fill` at ~55% of the shape width with a light drop shadow.

private enum Metrics {
    static let canvas: CGFloat = 1024
    static let margin: CGFloat = 100
    static let shape: CGFloat = canvas - margin * 2
    static let cornerRadius = shape * 0.2237
    static let symbolScale: CGFloat = 0.55
    static let amber = CGColor(srgbRed: 1, green: 179.0 / 255.0, blue: 64.0 / 255.0, alpha: 1)
    static let orange = CGColor(srgbRed: 1, green: 122.0 / 255.0, blue: 0, alpha: 1)
}

private func repoRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let arg0 = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: cwd).resolvingSymlinksInPath()
    let dir = arg0.deletingLastPathComponent()
    if dir.lastPathComponent == "scripts" {
        return dir.deletingLastPathComponent()
    }
    return cwd
}

private func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

/// Continuous rounded-rect (squircle) using Apple's three-cubic-per-corner construction.
private func squirclePath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = min(cornerRadius, min(rect.width, rect.height) / 2)
    let w = rect.width
    let h = rect.height
    let x = rect.minX
    let y = rect.minY

    func pt(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
        CGPoint(x: x + px, y: y + py)
    }

    // Coefficients from Apple's production icon template (iOS/macOS squircle).
    let c: CGFloat = 0.04631
    let d: CGFloat = 0.13357
    let e: CGFloat = 0.22097
    let f: CGFloat = 0.34864
    let g: CGFloat = 0.44576
    let k: CGFloat = 0.6074
    let i: CGFloat = 0.77025

    path.move(to: pt(r, 0))
    path.addLine(to: pt(w - r, 0))
    path.addCurve(to: pt(w - r * g, r * d), control1: pt(w - r * i, 0), control2: pt(w - r * k, r * c))
    path.addCurve(to: pt(w - r * d, r * g), control1: pt(w - r * f, r * e), control2: pt(w - r * e, r * f))
    path.addCurve(to: pt(w, r), control1: pt(w - r * c, r * k), control2: pt(w, r * i))
    path.addLine(to: pt(w, h - r))
    path.addCurve(to: pt(w - r * d, h - r * g), control1: pt(w, h - r * i), control2: pt(w - r * c, h - r * k))
    path.addCurve(to: pt(w - r * g, h - r * d), control1: pt(w - r * e, h - r * f), control2: pt(w - r * f, h - r * e))
    path.addCurve(to: pt(w - r, h), control1: pt(w - r * k, h - r * c), control2: pt(w - r * i, h))
    path.addLine(to: pt(r, h))
    path.addCurve(to: pt(r * g, h - r * d), control1: pt(r * i, h), control2: pt(r * k, h - r * c))
    path.addCurve(to: pt(r * d, h - r * g), control1: pt(r * f, h - r * e), control2: pt(r * e, h - r * f))
    path.addCurve(to: pt(0, h - r), control1: pt(r * c, h - r * k), control2: pt(0, h - r * i))
    path.addLine(to: pt(0, r))
    path.addCurve(to: pt(r * d, r * g), control1: pt(0, r * i), control2: pt(r * c, r * k))
    path.addCurve(to: pt(r * g, r * d), control1: pt(r * e, r * f), control2: pt(r * f, r * e))
    path.addCurve(to: pt(r, 0), control1: pt(r * k, r * c), control2: pt(r * i, 0))
    path.closeSubpath()
    return path
}

private func rasterizeSunSymbol(pointSize: CGFloat) -> CGImage {
    _ = NSApplication.shared
    guard let base = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "BrightBar") else {
        fail("SF Symbol sun.max.fill is unavailable")
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium, scale: .large)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = base.withSymbolConfiguration(config) else {
        fail("could not configure sun.max.fill")
    }

    let pixelW = max(1, Int(round(symbol.size.width)))
    let pixelH = max(1, Int(round(symbol.size.height)))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelW,
        pixelsHigh: pixelH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fail("could not create symbol bitmap")
    }
    rep.size = NSSize(width: pixelW, height: pixelH)

    NSGraphicsContext.saveGraphicsState()
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else {
        fail("could not create symbol graphics context")
    }
    gc.imageInterpolation = .high
    NSGraphicsContext.current = gc
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixelW, height: pixelH).fill()
    symbol.draw(
        in: NSRect(x: 0, y: 0, width: pixelW, height: pixelH),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let image = rep.cgImage else {
        fail("could not rasterize sun.max.fill")
    }
    return image
}

private func renderMasterIcon() -> CGImage {
    let pixels = Int(Metrics.canvas)
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create 1024×1024 bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.clear(CGRect(x: 0, y: 0, width: Metrics.canvas, height: Metrics.canvas))

    let shapeRect = CGRect(x: Metrics.margin, y: Metrics.margin, width: Metrics.shape, height: Metrics.shape)
    let path = squirclePath(in: shapeRect, cornerRadius: Metrics.cornerRadius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(path)
    ctx.setFillColor(Metrics.orange)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [Metrics.amber, Metrics.orange] as CFArray,
        locations: [0, 1]
    ) else {
        fail("could not create icon gradient")
    }
    // Unflipped CG: maxY is the visual top of the canvas.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: shapeRect.midX, y: shapeRect.maxY),
        end: CGPoint(x: shapeRect.midX, y: shapeRect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    let symbol = rasterizeSunSymbol(pointSize: Metrics.shape * Metrics.symbolScale)
    let symbolSize = CGSize(width: CGFloat(symbol.width), height: CGFloat(symbol.height))
    let symbolRect = CGRect(
        x: shapeRect.midX - symbolSize.width / 2,
        y: shapeRect.midY - symbolSize.height / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: CGColor(gray: 0, alpha: 0.28))
    ctx.draw(symbol, in: symbolRect)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        fail("could not finalize master icon")
    }
    return image
}

private func scaledImage(_ source: CGImage, pixels: Int) -> CGImage {
    if source.width == pixels && source.height == pixels {
        return source
    }
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create \(pixels)×\(pixels) bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = ctx.makeImage() else {
        fail("could not scale icon to \(pixels)px")
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fail("could not write PNG \(url.path)")
    }
}

private func runIconutil(iconset: URL, icns: URL) {
    try? FileManager.default.removeItem(at: icns)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError = FileHandle.standardError
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        fail("iconutil failed to start: \(error)")
    }
    guard proc.terminationStatus == 0 else {
        fail("iconutil exited \(proc.terminationStatus)")
    }
}

let root = repoRoot()
print("BrightBar icon generator")
print("repo root: \(root.path)")

let master = renderMasterIcon()
let pngURL = root.appendingPathComponent("Resources/Icon/icon-1024.png")
writePNG(master, to: pngURL)
print("wrote \(pngURL.path) (\(master.width)×\(master.height))")

let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("brightbar-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = tmpRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not create iconset dir: \(error)")
}
defer {
    try? FileManager.default.removeItem(at: tmpRoot)
}

// Apple's .iconset naming: 16, 32, 128, 256, 512 plus @2x (32, 64, 256, 512, 1024).
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for entry in entries {
    writePNG(scaledImage(master, pixels: entry.pixels), to: iconset.appendingPathComponent(entry.name))
}

let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
runIconutil(iconset: iconset, icns: icnsURL)
print("wrote \(icnsURL.path)")
print("done")
