// Fixtures.swift - Generates REAL image files with specific awkward properties.
//
// Nothing here is a mock: the files are written by ImageIO, so the probe and the encoders are
// tested against what actually lands on disk. Content is deterministic (seeded) so any failure
// reproduces.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

enum Fixtures {
    /// A fresh temp directory, removed by the caller (or the OS).
    static func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("io-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Small deterministic generator (xorshift) so "noise" is identical on every run.
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> UInt8 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }

    /// A photograph-ish image: smooth gradients, a few shapes and fine noise, which gives the
    /// encoders something realistic to compress (flat colours would flatter every encoder).
    static func photoLike(width: Int = 640, height: Int = 480,
                          colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                          seed: UInt64 = 42) -> CGImage {
        var rng = SeededRandom(state: seed)
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                var r = 255 * (0.5 + 0.5 * sin(fx * 9 + fy * 3))
                var g = 255 * (0.5 + 0.5 * cos(fy * 7 - fx * 2))
                var b = 255 * (0.3 + 0.7 * fx * fy)
                let dx = fx - 0.5, dy = fy - 0.45
                if dx * dx + dy * dy < 0.04 { r = 230; g = 90; b = 60 }
                let noise = Double(Int(rng.next() % 17)) - 8
                px[i] = UInt8(max(0, min(255, r + noise)))
                px[i + 1] = UInt8(max(0, min(255, g + noise)))
                px[i + 2] = UInt8(max(0, min(255, b + noise)))
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// A screenshot/UI-like image: flat panels, a gradient bar, thin lines, no noise. This is what
    /// real PNGs usually are (the benchmark's median real PNG shrank to 36%); photographic noise is
    /// the pathological case for a palette, so it must not stand in for typical use.
    static func uiLike(width: Int = 640, height: Int = 400,
                       colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let i = (y * width + x) * 4; px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
        }
        for y in 0..<height { for x in 0..<width { set(x, y, 244, 245, 248) } }                 // page
        for y in 20..<80 { for x in 20..<(width - 20) { set(x, y, 52, 120, 246) } }             // header
        for y in 100..<(height - 20) { for x in 20..<220 { set(x, y, 255, 255, 255) } }          // card
        for y in 300..<340 { for x in 40..<(width - 40) { let v = UInt8(Double(x - 40) / Double(width - 80) * 255); set(x, y, v, 120, 255 - v) } }
        for x in 0..<width { set(x, 90, 200, 200, 205); set(x, 91, 200, 200, 205) }              // rule
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Four coloured corners on grey. Non-square on purpose: it makes an axis swap visible.
    /// top-left red, top-right green, bottom-left blue, bottom-right yellow.
    static func cornerMarkers(width: Int = 96, height: Int = 48) -> CGImage {
        var px = [UInt8](repeating: 128, count: width * height * 4)
        func paint(_ x0: Int, _ y0: Int, _ c: (UInt8, UInt8, UInt8)) {
            for y in y0..<(y0 + 16) { for x in x0..<(x0 + 16) {
                let i = (y * width + x) * 4; px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
            } }
        }
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        paint(0, 0, (255, 0, 0)); paint(width - 16, 0, (0, 255, 0))
        paint(0, height - 16, (0, 0, 255)); paint(width - 16, height - 16, (255, 255, 0))
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType,
                      quality: Double? = nil, orientation: Int? = nil) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "no destination for \(type)"])
        }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Fixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "couldn't write \(url.lastPathComponent)"])
        }
        return url
    }

    /// A 2-frame animated GIF.
    static func animatedGIF(to url: URL) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil) else {
            throw NSError(domain: "Fixtures", code: 3)
        }
        CGImageDestinationAddImage(dest, photoLike(width: 32, height: 32, seed: 1), nil)
        CGImageDestinationAddImage(dest, photoLike(width: 32, height: 32, seed: 2), nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "Fixtures", code: 4) }
        return url
    }

    /// A greyscale image (single channel).
    static func grayscale(width: Int = 320, height: Int = 240) -> CGImage {
        var rng = SeededRandom(state: 7)
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            px[y * width + x] = UInt8(max(0, min(255, 128 + 100 * sin(Double(x) / 20) * cos(Double(y) / 25) + Double(rng.next() % 9))))
        } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    /// A 16-bit-per-channel image with a soft alpha ramp.
    static func sixteenBitWithAlpha(width: Int = 128, height: Int = 128) -> CGImage {
        var px = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let a = UInt16(Double(x) / Double(width) * 65535)
            // premultiplied: colour channels must not exceed alpha
            px[i] = a / 2; px[i + 1] = UInt16(Double(y) / Double(height) * Double(a)); px[i + 2] = a / 3; px[i + 3] = a
        } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        return ctx.makeImage()!
    }

    /// A CMYK image, written as JPEG.
    static func cmyk(width: Int = 64, height: Int = 64) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = 200; px[i + 1] = 40; px[i + 2] = 40; px[i + 3] = 10 }
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - Metadata fixtures and viewer-side pixels

extension Fixtures {
    /// Writes an image carrying the metadata a phone camera would: capture time, camera model,
    /// and a GPS location. Used to check that the metadata policy really strips them.
    @discardableResult
    static func writeWithCameraMetadata(_ image: CGImage, to url: URL, type: UTType,
                                        quality: Double = 0.9, orientation: Int? = nil) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05",
                kCGImagePropertyExifLensModel: "Test Lens 1.0",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "TestCam",
                kCGImagePropertyTIFFModel: "Model Z",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 43.6532, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 79.3832, kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "Fixtures", code: 2) }
        return url
    }

    /// What a viewer shows: orientation applied, colour-managed into sRGB, as 8-bit RGBA.
    /// Comparing these is the honest test that an optimised image still LOOKS the same.
    static func viewerPixels(_ url: URL) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
              ] as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (width, height, buf) : nil
    }

    /// Mean absolute difference per colour channel (0-255) between two same-size RGBA buffers.
    static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        precondition(a.count == b.count)
        var sum = 0.0
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { sum += Double(abs(Int(a[i + c]) - Int(b[i + c]))); n += 1 }
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
    }
}

/// Tests that need the real encoders skip themselves when `.tools/bin` hasn't been staged.
enum Requirements {
    static let jpegli = ToolLocator.url(for: .cjpegli) != nil
    static let png = ToolLocator.url(for: .oxipng) != nil && ToolLocator.url(for: .pngquant) != nil
}

// MARK: - Perceptual quality oracle

extension Fixtures {
    /// ssimulacra2 ships with libjxl and is a development-only dependency: it scores how different
    /// two images LOOK (70 good, 85 high quality, 90 very high). Never bundled with the app.
    static let ssimulacra2URL: URL? = {
        let candidates = [
            ProcessInfo.processInfo.environment["SSIMULACRA2"],
            "/Users/Wasim/.homebrew/bin/ssimulacra2", "/opt/homebrew/bin/ssimulacra2", "/usr/local/bin/ssimulacra2",
        ].compactMap { $0 }
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// Renders `url` the way a viewer shows it (upright, colour-managed, sRGB) into a PNG.
    static func renderViewerPNG(_ url: URL, to out: URL) -> Bool {
        guard let (w, h, rgba) = viewerPixels(url) else { return false }
        var buf = rgba
        let ok = buf.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image = ok, let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Perceptual score of `candidate` against `reference` (higher is better), or nil if unavailable.
    static func perceptualScore(reference: URL, candidate: URL, scratch: URL) -> Double? {
        guard let tool = ssimulacra2URL else { return nil }
        let a = scratch.appendingPathComponent("ref-\(UUID().uuidString.prefix(6)).png")
        let b = scratch.appendingPathComponent("cand-\(UUID().uuidString.prefix(6)).png")
        guard renderViewerPNG(reference, to: a), renderViewerPNG(candidate, to: b) else { return nil }
        let p = Process()
        p.executableURL = tool
        p.arguments = [a.path, b.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last ?? "")
    }
}

extension Requirements {
    static let oracle = Fixtures.ssimulacra2URL != nil
}
