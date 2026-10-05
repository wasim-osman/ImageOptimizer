// ImageProbe.swift - Reads an image's properties with ImageIO. No external tool involved.

import Foundation
import ImageIO

public enum ProbeError: LocalizedError, Sendable, Equatable {
    case unreadable(String)
    /// A format v1 deliberately doesn't handle. The associated value is a human name.
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Couldn't read this image: \(why)"
        case .unsupportedFormat(let name):
            return "\(name) isn't supported yet. ImageOptimizer handles JPEG, PNG and HEIC."
        }
    }
}

public enum ImageProbe {
    /// Friendly names for formats we recognise but refuse, so the message says what the file is.
    private static let refusedNames: [String: String] = [
        "com.compuserve.gif": "GIF",
        "public.tiff": "TIFF",
        "org.webmproject.webp": "WebP",
        "public.avif": "AVIF",
        "public.jpeg-2000": "JPEG 2000",
        "com.microsoft.bmp": "BMP",
        "com.adobe.photoshop-image": "Photoshop",
        "com.adobe.raw-image": "RAW",
        "public.camera-raw-image": "RAW",
        "com.adobe.pdf": "PDF",
        "public.svg-image": "SVG",
    ]

    public static func probe(url: URL) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ProbeError.unreadable("not a recognised image file")
        }
        guard let type = CGImageSourceGetType(source) as String? else {
            throw ProbeError.unreadable("unknown image type")
        }
        let format: ImageFormat
        switch type {
        case "public.jpeg": format = .jpeg
        case "public.png": format = .png
        case "public.heic", "public.heif": format = .heic
        default:
            throw ProbeError.unsupportedFormat(refusedNames[type] ?? type)
        }
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ProbeError.unreadable("no image data")
        }

        let colorModel: ColorModel
        switch props[kCGImagePropertyColorModel] as? String {
        case "RGB": colorModel = .rgb
        case "Gray": colorModel = .gray
        case "CMYK": colorModel = .cmyk
        case "Lab": colorModel = .lab
        default: colorModel = .other
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ImageInfo(
            format: format,
            width: width,
            height: height,
            orientation: props[kCGImagePropertyOrientation] as? Int ?? 1,
            bitDepth: props[kCGImagePropertyDepth] as? Int ?? 8,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            colorModel: colorModel,
            iccProfileName: props[kCGImagePropertyProfileName] as? String,
            frameCount: CGImageSourceGetCount(source),
            hasGainMap: hasGainMap(source),
            hasDepthData: hasDepthData(source),
            fileSize: size
        )
    }

    private static func hasDepthData(_ source: CGImageSource) -> Bool {
        [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth]
            .contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    private static func hasGainMap(_ source: CGImageSource) -> Bool {
        // The ISO gain-map constant isn't exposed as a Swift symbol on every SDK, so use its
        // string value. Checking both spellings catches Apple's and the ISO 21496-1 flavour.
        let types: [CFString] = [kCGImageAuxiliaryDataTypeHDRGainMap, "kCGImageAuxiliaryDataTypeISOGainMap" as CFString]
        return types.contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }
}
