// BloatGuard.swift - The two defences against making an image worse or no smaller.

import Foundation

public enum BloatGuardVerdict: Sendable, Equatable {
    case proceed
    case alreadyOptimised(reason: String)
}

public struct BloatGuard: Sendable {
    public init() {}

    /// Bits-per-pixel floors. A source already below its floor has been squeezed enough that a
    /// re-encode would cost quality and save nothing. Camera originals run 2-5 bpp, so these
    /// only catch files that were already optimised once. PNG has no floor: its size depends on
    /// content, not quality, and the post-flight check judges the real result.
    public static func bppFloor(format: ImageFormat, mode: EncoderMode) -> Double? {
        switch (format, mode) {
        case (.jpeg, .highQuality): return 1.6
        case (.jpeg, .balanced): return 1.0
        case (.jpeg, .smallest): return 0.7
        case (.heic, .highQuality): return 0.6
        case (.heic, .balanced): return 0.45
        case (.heic, .smallest): return 0.35
        case (.png, _): return nil
        }
    }

    /// Below this a file is already about as small as its container allows.
    public static let minimumWorthwhileBytes: Int64 = 2_000

    public func preflight(_ info: ImageInfo, mode: EncoderMode) -> BloatGuardVerdict {
        if info.fileSize > 0, info.fileSize < Self.minimumWorthwhileBytes {
            return .alreadyOptimised(reason: "Already tiny — \(info.fileSize) bytes can't be meaningfully reduced.")
        }
        guard let floor = Self.bppFloor(format: info.format, mode: mode), info.bitsPerPixel > 0 else {
            return .proceed   // unknown density must not be read as "efficient"
        }
        guard info.bitsPerPixel >= floor else {
            return .alreadyOptimised(
                reason: "Already optimised — \(String(format: "%.2f", info.bitsPerPixel)) bits/pixel is below the "
                    + "\(String(format: "%.2f", floor)) floor for \(info.format.displayName). "
                    + "Re-encoding would only lose quality."
            )
        }
        return .proceed
    }

    /// A lossy result must beat 92% of the input to be worth the generational loss. A lossless
    /// result costs nothing in quality, so any genuine saving is kept (but not byte-identical).
    public static func postFlightShouldDiscard(inputSize: Int64, outputSize: Int64, lossless: Bool) -> Bool {
        guard inputSize > 0 else { return false }
        let ratio = Double(outputSize) / Double(inputSize)
        return lossless ? ratio >= 1.0 : ratio >= 0.92
    }
}
