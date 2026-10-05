// OutputFinalizer.swift - Turns a finished `.part` file into the real output, or discards it.

import Foundation

enum OutputFinalizer {
    enum Outcome: Equatable {
        case promoted(size: Int64)
        case discarded(message: String)
    }

    /// Applies the post-flight guard, then moves `partURL` onto `outputURL`.
    ///
    /// Overwrite uses `replaceItemAt`: a plain move refuses to replace an existing file, which
    /// silently produced no output under the default overwrite policy in VideoOptimizer.
    static func finalize(
        partURL: URL,
        outputURL: URL,
        inputURL: URL,
        inputSize: Int64,
        lossless: Bool,
        bypassGuard: Bool,
        preserveDates: Bool
    ) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: partURL.path) else {
            throw EncodeError.encodeFailed("the encoder finished but wrote no file")
        }
        let outputSize = (try fm.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
        guard outputSize > 0 else {
            try? fm.removeItem(at: partURL)
            throw EncodeError.encodeFailed("the encoder wrote an empty file")
        }
        if !bypassGuard, BloatGuard.postFlightShouldDiscard(inputSize: inputSize, outputSize: outputSize, lossless: lossless) {
            try? fm.removeItem(at: partURL)
            let percent = inputSize > 0 ? Int((Double(outputSize) / Double(inputSize) * 100).rounded()) : 100
            let message = lossless
                ? "Already as small as it can be losslessly — the result was no smaller, so nothing was written."
                : "The result was \(percent)% of the original, so nothing was written — this image was already efficient."
            return .discarded(message: message)
        }
        do {
            if fm.fileExists(atPath: outputURL.path) {
                _ = try fm.replaceItemAt(outputURL, withItemAt: partURL)
            } else {
                try fm.moveItem(at: partURL, to: outputURL)
            }
        } catch {
            try? fm.removeItem(at: partURL)
            throw EncodeError.encodeFailed("couldn't save to \(outputURL.lastPathComponent): \(error.localizedDescription)")
        }
        if preserveDates, let attrs = try? fm.attributesOfItem(atPath: inputURL.path) {
            var carry: [FileAttributeKey: Any] = [:]
            if let created = attrs[.creationDate] { carry[.creationDate] = created }
            if let modified = attrs[.modificationDate] { carry[.modificationDate] = modified }
            try? fm.setAttributes(carry, ofItemAtPath: outputURL.path)
        }
        return .promoted(size: outputSize)
    }
}
