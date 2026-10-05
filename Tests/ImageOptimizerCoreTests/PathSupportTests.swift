// PathSupportTests.swift - Output naming and conflict handling.

import Foundation
import Testing
@testable import ImageOptimizerCore

@Suite("PathSupport")
final class PathSupportTests {
    private let dir: URL

    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    private func out(_ name: String, location: OutputLocation = .sameAsSource, folder: String = "",
                     policy: ResolveConflict = .overwrite, suffix: String = "_optimized") -> URL {
        PathSupport.outputURL(inputURL: dir.appendingPathComponent(name), suffix: suffix, outputLocation: location,
                              chosenFolderPath: folder, conflictPolicy: policy)
    }

    @Test("a colon is neutralised because POSIX reads it as a separator")
    func colon() {
        let safe = PathSupport.sanitisedBaseName("Trip: Day 2")
        #expect(!safe.contains(":") && !safe.contains("/"))
    }

    @Test("a leading dot is neutralised so the output isn't hidden")
    func leadingDot() { #expect(!PathSupport.sanitisedBaseName(".hidden").hasPrefix(".")) }

    @Test("the output sits beside the source with the suffix and the same extension")
    func beside() {
        let url = out("IMG_1.jpeg")
        #expect(url.deletingLastPathComponent().path == dir.path)
        #expect(url.lastPathComponent == "IMG_1_optimized.jpeg")
    }

    @Test("a chosen folder is honoured")
    func chosen() {
        let elsewhere = dir.appendingPathComponent("out")
        #expect(out("a.png", location: .chooseFolder, folder: elsewhere.path).deletingLastPathComponent().path == elsewhere.path)
    }

    @Test("numberIt finds a free name, counting past several collisions")
    func numbering() throws {
        for n in ["a_optimized.png", "a_optimized 1.png", "a_optimized 2.png"] {
            try Data().write(to: dir.appendingPathComponent(n))
        }
        let url = out("a.png", policy: .numberIt)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "a_optimized 3.png")
    }

    @Test("a file with no extension still gets a sensible output name")
    func noExtension() { #expect(out("README").lastPathComponent == "README_optimized") }
}
