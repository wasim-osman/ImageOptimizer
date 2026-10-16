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
import CoreImage
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
    /// Develops a camera RAW with Apple's own RAW engine (the one Preview and Photos use), so the
    /// JPEG looks like what the Mac shows for that file. The engine applies the camera's rotation
    /// itself, so the pixels come out upright and must not be rotated again. They are rendered in
    /// Display P3, which keeps wide-gamut colour, and that profile is embedded in the JPEG.
    static func extractRAW(url: URL, maxSide: Int? = nil) throws -> DecodedPixels {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw EncodeError.decodeFailed("this macOS version can't develop RAW files from this camera. Updating macOS adds newer cameras")
        }
        // Develop at the smaller size directly (cheaper and sharper than shrinking afterwards).
        if let maxSide, maxSide > 0 {
            let native = max(filter.nativeSize.width, filter.nativeSize.height)
            if native > CGFloat(maxSide) { filter.scaleFactor = Float(CGFloat(maxSide) / native) }
        }
        guard let developed = filter.outputImage else {
            throw EncodeError.decodeFailed("this macOS version can't develop RAW files from this camera. Updating macOS adds newer cameras")
        }
        let extent = developed.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw EncodeError.decodeFailed("empty RAW image")
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buf in
            CIContext(options: [.cacheIntermediates: false])
                .render(developed, toBitmap: buf.baseAddress!, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: space)
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgba.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                var s = 0, d = 0
                while s < src.count {
                    dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]
                    s += 4; d += 3
                }
            }
        }
        return DecodedPixels(width: width, height: height, isGray: false, bytes: rgb, iccProfile: space.copyICCData() as Data?)
    }

    /// `maxSide` shrinks the picture so its longer side fits (never enlarges).
    static func extract(url: URL, info: ImageInfo, maxSide: Int? = nil) throws -> DecodedPixels {
        if info.format == .raw { return try extractRAW(url: url, maxSide: maxSide) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EncodeError.decodeFailed("couldn't open \(url.lastPathComponent)")
        }
        // The thumbnail path is how ImageIO applies EXIF orientation. Asking for the full
        // dimension means it rotates without resampling.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(info.width, info.height), maxSide ?? .max),
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
