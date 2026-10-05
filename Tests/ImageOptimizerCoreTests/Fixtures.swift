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
