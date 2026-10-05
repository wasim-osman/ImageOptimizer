// ImageInfo.swift - What the probe learns about an image before any encoding decision.

import Foundation

/// The formats v1 can optimise. Everything else is refused with a reason, never mangled.
public enum ImageFormat: String, Sendable, Codable, Equatable, CaseIterable {
    case jpeg, png, heic

    public var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        }
    }
}

public enum ColorModel: String, Sendable, Codable, Equatable {
    case rgb, gray, cmyk, lab, other
}

public struct ImageInfo: Sendable, Codable, Equatable {
    public var format: ImageFormat
    /// Stored pixel dimensions, BEFORE the EXIF orientation is applied.
    public var width: Int
    public var height: Int
    /// EXIF orientation 1...8. 1 = upright. Anything else means the stored pixels are rotated
    /// or mirrored and a viewer is expected to correct them.
    public var orientation: Int
    public var bitDepth: Int
    public var hasAlpha: Bool
    public var colorModel: ColorModel
    /// Embedded ICC profile description, e.g. "Display P3". nil when the image carries none.
    public var iccProfileName: String?
    public var frameCount: Int
    /// iPhone HDR photos carry a gain map ImageIO cannot carry across a re-encode.
    public var hasGainMap: Bool
    /// Portrait-mode photos carry a depth/disparity map that a re-encode would silently delete.
    public var hasDepthData: Bool
    public var fileSize: Int64

    public init(
        format: ImageFormat,
        width: Int,
        height: Int,
        orientation: Int = 1,
        bitDepth: Int = 8,
        hasAlpha: Bool = false,
        colorModel: ColorModel = .rgb,
        iccProfileName: String? = nil,
        frameCount: Int = 1,
        hasGainMap: Bool = false,
        hasDepthData: Bool = false,
        fileSize: Int64
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.orientation = orientation
        self.bitDepth = bitDepth
        self.hasAlpha = hasAlpha
        self.colorModel = colorModel
        self.iccProfileName = iccProfileName
        self.frameCount = frameCount
        self.hasGainMap = hasGainMap
        self.hasDepthData = hasDepthData
        self.fileSize = fileSize
    }

    public var pixelCount: Int { width * height }
    public var megapixels: Double { Double(pixelCount) / 1_000_000 }
    public var isAnimated: Bool { frameCount > 1 }

    /// Bits of file per pixel, the image counterpart of video's bits-per-pixel-per-frame:
    /// the single most useful number for telling a fat camera original from a file that has
    /// already been squeezed.
    public var bitsPerPixel: Double {
        guard pixelCount > 0 else { return 0 }
        return Double(fileSize * 8) / Double(pixelCount)
    }

    /// Dimensions as a viewer shows them, i.e. after orientation (5...8 swap the axes).
    public var displayWidth: Int { (5...8).contains(orientation) ? height : width }
    public var displayHeight: Int { (5...8).contains(orientation) ? width : height }

    /// True when the profile is absent or plainly sRGB, i.e. nothing colour-managed to lose.
    public var isPlainSRGB: Bool {
        guard let name = iccProfileName?.lowercased() else { return true }
        return name.contains("srgb")
    }
}
