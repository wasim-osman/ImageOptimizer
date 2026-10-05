// IdleSummary.swift - What the drop zone shows once nothing is actively converting.

import Foundation

public enum IdleSummary {
    public static func headline(for jobs: [Job]) -> String {
        func count(_ states: JobState...) -> Int { jobs.filter { states.contains($0.state) }.count }
        var parts: [String] = []
        let succeeded = count(.succeeded), skipped = count(.alreadyOptimized, .discardedAsBlob)
        let unsupported = count(.unsupported), cancelled = count(.cancelled), failed = count(.failed)
        if succeeded > 0 { parts.append("\(succeeded) optimised") }
        if skipped > 0 { parts.append("\(skipped) already optimised") }
        if unsupported > 0 { parts.append("\(unsupported) unsupported") }
        if cancelled > 0 { parts.append("\(cancelled) stopped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Drop images here" : parts.joined(separator: " · ")
    }

    /// A succeeded batch's before/after summary wins; otherwise the most recent failure's, then
    /// refusal's own message — never a blank line, because every outcome already carries its reason.
    public static func detail(for jobs: [Job]) -> String {
        let converted = jobs.filter { $0.state == .succeeded }
        if !converted.isEmpty {
            let before = converted.reduce(Int64(0)) { $0 + $1.inputSize }
            let after = converted.reduce(Int64(0)) { $0 + ($1.resultSize ?? $1.inputSize) }
            guard before > 0 else { return "" }
            let percent = Int((1 - Double(after) / Double(before)) * 100)
            // A forced conversion can grow a file; "(−-12%)" would be nonsense.
            let text = percent >= 0 ? "−\(percent)%" : "+\(-percent)% larger"
            return "\(formatBytes(before)) → \(formatBytes(after)) (\(text)) · click to show in Finder"
        }
        if let failed = jobs.last(where: { $0.state == .failed }), !failed.error.isEmpty { return failed.error }
        if let skipped = jobs.last(where: { [.alreadyOptimized, .discardedAsBlob, .unsupported].contains($0.state) }),
           !skipped.error.isEmpty {
            return skipped.error
        }
        return ""
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
