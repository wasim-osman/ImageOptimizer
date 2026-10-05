// ToolLocator.swift - Finds the bundled encoders.

import Foundation

public enum Tool: String, Sendable, CaseIterable {
    case cjpegli, oxipng, pngquant
}

public enum ToolLocator {
    /// Where to look, in priority order. The bundle comes first so a shipped app never picks up
    /// a stray system copy; `.tools/bin` (found by walking up from the working directory) serves
    /// development and `swift test`.
    public static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["IMAGEOPTIMIZER_TOOLS_DIR"] {
            dirs.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("bin", isDirectory: true))
        }
        var walk = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            dirs.append(walk.appendingPathComponent(".tools/bin", isDirectory: true))
            let parent = walk.deletingLastPathComponent()
            if parent == walk { break }
            walk = parent
        }
        return dirs
    }

    public static func url(for tool: Tool) -> URL? {
        for dir in searchDirectories() {
            let candidate = dir.appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Which tools a format needs. HEIC uses Apple's encoder in-process, so it needs none.
    public static func tools(for format: ImageFormat) -> [Tool] {
        switch format {
        case .jpeg: return [.cjpegli]
        case .png: return [.oxipng, .pngquant]
        case .heic: return []
        }
    }

    public static func missing(for format: ImageFormat) -> [Tool] {
        tools(for: format).filter { url(for: $0) == nil }
    }
}
