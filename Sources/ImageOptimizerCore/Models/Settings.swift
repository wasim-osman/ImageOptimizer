// Settings.swift - User preferences driving the quality engine.

import Foundation

/// How hard to push. Unlike video, every image encode is quick, so these trade quality for
/// size rather than speed.
public enum EncoderMode: String, Sendable, CaseIterable, Codable {
    case highQuality
    case balanced
    case smallest

    public var displayName: String {
        switch self {
        case .highQuality: return "High quality"
        case .balanced: return "Balanced"
        case .smallest: return "Smallest"
        }
    }
}

public enum OutputLocation: String, Sendable, CaseIterable, Codable {
    case sameAsSource
    case chooseFolder
}

public enum ResolveConflict: String, Sendable, CaseIterable, Codable {
    case overwrite
    case numberIt
    case skip
}

public struct Settings: Sendable, Codable, Equatable {
    public var encoderMode: EncoderMode = .balanced
    /// Allow pngquant's lossy palette reduction. Off means PNGs are only ever recompressed
    /// losslessly, pixel for pixel.
    public var pngLossy: Bool = true
    public var outputLocation: OutputLocation = .sameAsSource
    public var chosenFolderPath: String = ""
    public var suffix: String = "_optimized"
    public var conflictPolicy: ResolveConflict = .overwrite
    /// Moves the original to the Trash after a successful conversion.
    public var deleteSource: Bool = false
    public var preserveDates: Bool = true
    /// Images converted at once. 0 means automatic: one per CPU core. Every encoder here is single-threaded
    /// per file (gifsicle, cjpegli, pngquant), so parallel files are the only way to use more than one core.
    public var concurrency: Int = 0
    public var effectiveConcurrency: Int { concurrency > 0 ? concurrency : max(1, ProcessInfo.processInfo.activeProcessorCount) }

    public init() {}
}
