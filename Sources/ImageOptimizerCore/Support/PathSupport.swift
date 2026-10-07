// PathSupport.swift - Output naming and conflict handling.

import Foundation

public enum PathSupport {
    /// ":" is legal in Finder but is a path separator at the POSIX layer.
    public static func sanitisedBaseName(_ fileName: String) -> String {
        var base = fileName.replacingOccurrences(of: ":", with: "_")
        base = base.replacingOccurrences(of: "\0", with: "")
        if base.hasPrefix(".") { base = "_" + base }
        return base
    }

    /// `<name><suffix>.<ext>`, beside the source or in the chosen folder. The extension is the
    /// source's own (images keep their format, so a .jpeg stays a .jpeg) unless `outputExtension`
    /// says otherwise, as it does for a RAW file that becomes a .jpg.
    public static func outputURL(
        inputURL: URL,
        suffix: String,
        outputLocation: OutputLocation,
        chosenFolderPath: String,
        conflictPolicy: ResolveConflict,
        outputExtension: String? = nil
    ) -> URL {
        let ext = outputExtension ?? inputURL.pathExtension
        let safe = sanitisedBaseName(inputURL.deletingPathExtension().lastPathComponent)
        let directory: URL
        switch outputLocation {
        case .sameAsSource: directory = inputURL.deletingLastPathComponent()
        case .chooseFolder: directory = URL(fileURLWithPath: chosenFolderPath, isDirectory: true)
        }
        func name(_ extra: String) -> String { ext.isEmpty ? safe + suffix + extra : "\(safe)\(suffix)\(extra).\(ext)" }
        var candidate = directory.appendingPathComponent(name(""))

        // An output must never land on its own input, even when the suffix is empty.
        if candidate.standardizedFileURL == inputURL.standardizedFileURL {
            candidate = directory.appendingPathComponent(name("_1"))
        }
        guard conflictPolicy == .numberIt else { return candidate }
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(name(" \(counter)"))
            counter += 1
        }
        return candidate
    }
}
