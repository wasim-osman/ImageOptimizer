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
    /// Metadata groups to leave out of the result. Everything else in the source's metadata is kept. Only
    /// the location by default, so a photo never leaves with where it was taken unless the user says so.
    public var removeMetadata: Set<MetadataCategory> = MetadataCategory.defaultRemoved
    public var effectiveConcurrency: Int { concurrency > 0 ? concurrency : max(1, ProcessInfo.processInfo.activeProcessorCount) }

    public init() {}

    // Written by hand so a settings file saved by an older version (missing newer keys) still loads, instead of
    // being thrown away whole.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        encoderMode = try c.decodeIfPresent(EncoderMode.self, forKey: .encoderMode) ?? d.encoderMode
        pngLossy = try c.decodeIfPresent(Bool.self, forKey: .pngLossy) ?? d.pngLossy
        outputLocation = try c.decodeIfPresent(OutputLocation.self, forKey: .outputLocation) ?? d.outputLocation
        chosenFolderPath = try c.decodeIfPresent(String.self, forKey: .chosenFolderPath) ?? d.chosenFolderPath
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? d.suffix
        conflictPolicy = try c.decodeIfPresent(ResolveConflict.self, forKey: .conflictPolicy) ?? d.conflictPolicy
        deleteSource = try c.decodeIfPresent(Bool.self, forKey: .deleteSource) ?? d.deleteSource
        preserveDates = try c.decodeIfPresent(Bool.self, forKey: .preserveDates) ?? d.preserveDates
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? d.concurrency
        removeMetadata = try c.decodeIfPresent(Set<MetadataCategory>.self, forKey: .removeMetadata) ?? d.removeMetadata
    }
}
