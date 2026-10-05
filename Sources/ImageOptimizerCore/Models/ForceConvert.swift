// ForceConvert.swift - The "convert anyway?" decision for a file dropped again after a refusal.

import Foundation

public enum ForceConvert {
    /// The past job to explain, when dropping `url` again should offer "Convert Anyway?".
    ///
    /// Only when the single MOST RECENT attempt at this exact file was a size-guard refusal. Not
    /// the most recent refusal: a file that has since succeeded has nothing left to force. And
    /// never for `.unsupported` — forcing an animated file would not make it safe.
    public static func shouldPromptToForce(url: URL, among jobs: [Job]) -> Job? {
        let standardized = url.standardizedFileURL
        guard let mostRecent = jobs.last(where: { $0.inputURL.standardizedFileURL == standardized }) else {
            return nil
        }
        guard [.alreadyOptimized, .discardedAsBlob, .hdrLayer].contains(mostRecent.state) else { return nil }
        return mostRecent
    }
}
