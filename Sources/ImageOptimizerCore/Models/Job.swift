// Job.swift - One image's journey through the queue.

import Foundation

public enum JobState: String, Sendable, Codable, Equatable {
    case queued
    case probing
    case planning
    case encoding
    case succeeded
    case failed
    case cancelled
    /// Refused by a size guard: already efficient, or the result would not have been smaller.
    /// The only refusal "Convert Anyway" can override.
    case alreadyOptimized
    case discardedAsBlob
    /// Refused because the file can't be optimised safely (animated, CMYK, HDR gain map, a
    /// format v1 doesn't handle). Forcing would not help, so it is never offered.
    case unsupported
}

public struct Job: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var inputURL: URL
    public var inputSize: Int64
    public var state: JobState
    public var progress: Double
    public var error: String = ""
    public var resultURL: URL?
    public var resultSize: Int64?
    public var forceEncode: Bool

    public init(inputURL: URL, forceEncode: Bool = false) {
        self.id = UUID()
        self.inputURL = inputURL
        self.inputSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        self.state = .queued
        self.progress = 0
        self.forceEncode = forceEncode
    }

    public var isActive: Bool {
        switch state {
        case .queued, .probing, .planning, .encoding: return true
        default: return false
        }
    }
}
