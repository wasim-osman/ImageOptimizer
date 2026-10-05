// LifetimeStats.swift - Cumulative bytes saved across every successful conversion, ever.

import Foundation

public struct LifetimeStats: Codable, Equatable, Sendable {
    public var totalInputBytes: Int64 = 0
    public var totalOutputBytes: Int64 = 0
    public var filesConverted: Int = 0

    public init() {}

    /// Clamped so a display value never goes negative.
    public var totalBytesSaved: Int64 { max(0, totalInputBytes - totalOutputBytes) }

    public mutating func record(inputBytes: Int64, outputBytes: Int64) {
        totalInputBytes += inputBytes
        totalOutputBytes += outputBytes
        filesConverted += 1
    }
}
