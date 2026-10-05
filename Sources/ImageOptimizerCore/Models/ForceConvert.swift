// ForceConvert.swift - The "convert anyway?" decision for a file dropped again after a refusal.

import Foundation

public enum ForceConvert {
    /// The past job to explain, when dropping `url` again should offer "Convert Anyway?".
    ///
    /// Only when the single MOST RECENT attempt at this exact file was a size-guard refusal. Not
    /// the most recent refusal: a file that has since succeeded has nothing left to force. And
    /// never for `.unsupported` — forcing an animated or HDR file would not make it safe.
    public static func shouldPromptToForce(url: URL, among jobs: [Job]) -> Job? {
        let standardized = url.standardizedFileURL
        guard let mostRecent = jobs.last(where: { $0.inputURL.standardizedFileURL == standardized }) else {
            return nil
        }
        guard mostRecent.state == .alreadyOptimized || mostRecent.state == .discardedAsBlob else { return nil }
        return mostRecent
    }
}
