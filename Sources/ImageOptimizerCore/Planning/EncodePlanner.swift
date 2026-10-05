// EncodePlanner.swift - Pure function: ImageInfo + Settings -> ImagePlan. No I/O, no tools.

import Foundation

/// One stage of the encode pipeline. The encoder runs them in order.
public enum EncodeStep: Sendable, Equatable {
    /// jpegli. `distance` is a Butteraugli distance: lower is better, 1.0 is "visually lossless".
    case jpegli(distance: Double, chromaSubsampling: String?)
    /// pngquant lossy palette reduction. A result below `minQuality` is skipped, not forced.
    case pngquant(minQuality: Int, maxQuality: Int, speed: Int)
    /// oxipng lossless recompression. Always `--strip safe`, which keeps the colour profile.
    case oxipng(level: Int)
    /// Apple's HEVC encoder, in-process. Orientation and colour profile are carried across.
    case heic(quality: Double)
}

public enum Refusal: Sendable, Equatable {
    /// Already efficient. The user may override with "Convert Anyway".
    case alreadyEfficient(String)
    /// Can't be optimised safely. Forcing would not help.
    case unsupported(String)

    public var reason: String {
        switch self {
        case .alreadyEfficient(let r), .unsupported(let r): return r
        }
    }
}

public enum PlanOutcome: Sendable, Equatable {
    case planned
    case refused(Refusal)
}

public struct ImagePlan: Sendable, Equatable {
    public var inputURL: URL
    public var outputURL: URL
    public var outcome: PlanOutcome
    public var steps: [EncodeStep]
    /// True when every step preserves pixels exactly, which lets the post-flight guard keep
    /// even a small saving.
    public var isLossless: Bool
    public var qualityNote: String
}

public struct EncodePlanner: Sendable {
    private let bloatGuard = BloatGuard()

    /// Refuse enormous images rather than exhaust memory decoding them.
    public static let maximumMegapixels = 150.0

    public init() {}

    public func plan(info: ImageInfo, inputURL: URL, settings: Settings, forceEncode: Bool = false) -> ImagePlan {
        let outputURL = PathSupport.outputURL(
            inputURL: inputURL, suffix: settings.suffix,
            outputLocation: settings.outputLocation,
            chosenFolderPath: settings.chosenFolderPath,
            conflictPolicy: settings.conflictPolicy
        )
        func refused(_ r: Refusal) -> ImagePlan {
            ImagePlan(inputURL: inputURL, outputURL: outputURL, outcome: .refused(r), steps: [], isLossless: false, qualityNote: "")
        }

        // 1. Things we can't optimise safely. Never overridable.
        if info.isAnimated {
            return refused(.unsupported("Animated images aren't supported — re-encoding would flatten the animation to one frame."))
        }
        if info.colorModel == .cmyk {
            return refused(.unsupported("CMYK images aren't supported — converting them would change the colours."))
        }
        if info.hasGainMap {
            return refused(.unsupported("HDR photos aren't supported yet — re-encoding would silently remove the HDR (gain map)."))
        }
        if info.hasDepthData {
            return refused(.unsupported("Portrait photos aren't supported yet — re-encoding would delete the depth data Photos uses for portrait editing."))
        }
        if info.megapixels > Self.maximumMegapixels {
            return refused(.unsupported("This image is \(Int(info.megapixels)) megapixels — too large to process safely."))
        }

        // 2. Size guard. This is the one the user may override.
        if !forceEncode, case .alreadyOptimised(let reason) = bloatGuard.preflight(info, mode: settings.encoderMode) {
            return refused(.alreadyEfficient(reason))
        }

        // 3. The ladder.
        let mode = settings.encoderMode
        var steps: [EncodeStep]
        var lossless = false
        let note: String
        switch info.format {
        case .jpeg:
            let distance: Double
            var chroma: String? = nil
            switch mode {
            case .highQuality: distance = 0.6
            case .balanced: distance = 1.0
            case .smallest: distance = 1.7; chroma = "420"
            }
            steps = [.jpegli(distance: distance, chromaSubsampling: chroma)]
            note = "jpegli distance \(distance)"
        case .png:
            let useLossy = settings.pngLossy && mode != .highQuality
            if useLossy {
                switch mode {
                case .smallest: steps = [.pngquant(minQuality: 70, maxQuality: 95, speed: 1), .oxipng(level: 4)]
                default: steps = [.pngquant(minQuality: 80, maxQuality: 98, speed: 3), .oxipng(level: 4)]
                }
                note = "pngquant + oxipng"
            } else {
                steps = [.oxipng(level: 4)]
                lossless = true
                note = "oxipng lossless"
            }
        case .heic:
            let quality: Double
            switch mode {
            case .highQuality: quality = 0.85
            case .balanced: quality = 0.70
            case .smallest: quality = 0.55
            }
            steps = [.heic(quality: quality)]
            note = "HEIC quality \(quality)"
        }
        return ImagePlan(inputURL: inputURL, outputURL: outputURL, outcome: .planned, steps: steps,
                         isLossless: lossless, qualityNote: note)
    }
}
