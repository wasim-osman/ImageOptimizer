// PixelExtractor.swift - Decodes a JPEG to raw pixels for jpegli, getting orientation and
// colour right.
//
// Two traps, both measured on real photos in the milestone 1 benchmark:
//  * Orientation. A bare decode returns the stored (unrotated) pixels. Dropping the EXIF tag
//    without rotating them makes the photo display sideways. We rotate the pixels, so the output
//    needs no orientation tag at all.
//  * Colour. Pixels must be rendered in the image's OWN colour space, and that profile embedded
//    in the output. Converting to sRGB would clip a Display P3 photo; dropping the profile
//    would wash it out.

import CoreGraphics
import Foundation
import ImageIO

struct DecodedPixels: @unchecked Sendable {
    var width: Int
    var height: Int
    var isGray: Bool
    /// Tightly packed RGB (3 bytes/pixel) or Gray (1 byte/pixel), already upright.
    var bytes: [UInt8]
    /// The profile to embed, or nil when the image is plain sRGB (untagged is read as sRGB).
    var iccProfile: Data?

    /// The PNM header jpegli reads: P6 for RGB, P5 for greyscale.
    var pnmHeader: Data { Data("\(isGray ? "P5" : "P6")\n\(width) \(height)\n255\n".utf8) }
}

enum PixelExtractor {
    static func extract(url: URL, info: ImageInfo) throws -> DecodedPixels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EncodeError.decodeFailed("couldn't open \(url.lastPathComponent)")
        }
        // The thumbnail path is how ImageIO applies EXIF orientation. Asking for the full
        // dimension means it rotates without resampling.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EncodeError.decodeFailed("couldn't decode \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        guard width * height > 0 else { throw EncodeError.decodeFailed("empty image") }

        if info.colorModel == .gray {
            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw EncodeError.decodeFailed("couldn't render greyscale pixels") }
            return DecodedPixels(width: width, height: height, isGray: true, bytes: gray, iccProfile: nil)
        }

        // Render in the image's own RGB space; fall back to sRGB only if it has none we can use.
        var space = image.colorSpace
        if space == nil || space?.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB) }
        guard let renderSpace = space else { throw EncodeError.decodeFailed("no colour space") }

        var rgbx = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgbx.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: renderSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EncodeError.decodeFailed("couldn't render RGB pixels") }

        // Pack RGBX -> RGB.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgbx.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                var s = 0, d = 0
                let pixels = width * height
                for _ in 0..<pixels {
                    dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]
                    s += 4; d += 3
                }
            }
        }

        // Embed a profile only when the source had a non-sRGB one. An sRGB profile is ~3 KB of
        // dead weight, and untagged JPEGs are read as sRGB anyway.
        var icc: Data? = nil
        if !info.isPlainSRGB, let data = renderSpace.copyICCData() as Data? { icc = data }
        return DecodedPixels(width: width, height: height, isGray: false, bytes: rgb, iccProfile: icc)
    }
}
