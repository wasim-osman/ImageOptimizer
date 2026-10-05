// QualityOracleTests.swift - Does an optimised image still LOOK like the original?
//
// Size alone can't tell you that: an encoder that smeared every image would "win" any
// size comparison. These tests score the result with ssimulacra2 against the source.
//
// Thresholds are the minimum scores seen across 30 real JPEGs / 24 real PNGs / 8 real HEICs in
// the real-photo validation (see docs/ENGINE-FINDINGS.md), minus a safety margin. They are NOT
// tuned to whatever the synthetic fixtures here happen to score.

import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("QualityOracle", .serialized, .timeLimit(.minutes(5)),
       .enabled(if: Requirements.oracle && Requirements.jpegli && Requirements.png))
final class QualityOracleTests {
    private let dir: URL
    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    private func optimise(_ src: URL, mode: EncoderMode) async throws -> URL {
        let info = try ImageProbe.probe(url: src)
        var s = Settings(); s.encoderMode = mode; s.pngLossy = true
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: s, forceEncode: true)
        let out = dir.appendingPathComponent("o-\(UUID().uuidString.prefix(6)).\(src.pathExtension)")
        _ = try await ImageEncoder().encode(plan: plan, info: info, to: out)
        return out
    }

    private func score(_ ref: URL, _ out: URL) throws -> Double {
        try #require(Fixtures.perceptualScore(reference: ref, candidate: out, scratch: dir), "ssimulacra2 produced no score")
    }

    // Minimum real-photo scores: JPEG high 86.0 / balanced 80.9 / smallest 68.3.
    @Test("JPEG quality floors hold per mode", arguments: [(EncoderMode.highQuality, 82.0), (.balanced, 77.0), (.smallest, 62.0)])
    func jpegFloors(mode: EncoderMode, floor: Double) async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1280, height: 960), to: dir.appendingPathComponent("p-\(mode.rawValue).jpg"), type: .jpeg, quality: 0.97)
        let s = try score(src, try await optimise(src, mode: mode))
        #expect(s >= floor, "\(mode) scored \(s), below the floor \(floor)")
    }

    @Test("the JPEG modes are ordered by perceptual quality")
    func jpegModesOrdered() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1280, height: 960), to: dir.appendingPathComponent("ord.jpg"), type: .jpeg, quality: 0.97)
        let high = try score(src, try await optimise(src, mode: .highQuality))
        let balanced = try score(src, try await optimise(src, mode: .balanced))
        let smallest = try score(src, try await optimise(src, mode: .smallest))
        #expect(high > balanced && balanced > smallest, "high \(high), balanced \(balanced), smallest \(smallest)")
    }

    @Test("a Display P3 JPEG doesn't lose perceptual quality to a colour error")
    func wideGamutJPEGScoresWell() async throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = try Fixtures.write(Fixtures.photoLike(width: 1024, height: 768, colorSpace: p3), to: dir.appendingPathComponent("p3.jpg"), type: .jpeg, quality: 0.97)
        let s = try score(src, try await optimise(src, mode: .balanced))
        #expect(s >= 77, "a colour-profile mistake shows up as a big score drop; got \(s)")
    }

    @Test("a rotated JPEG scores well, because a rotation error would score terribly")
    func rotatedJPEGScoresWell() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1024, height: 768), to: dir.appendingPathComponent("rot.jpg"), type: .jpeg, quality: 0.97, orientation: 6)
        let s = try score(src, try await optimise(src, mode: .balanced))
        #expect(s >= 77, "got \(s)")
    }

    // Minimum real-photo scores: PNG lossless 100 (exact) / balanced 73.3 (real photos & graphics).
    @Test("lossless PNG scores as identical")
    func losslessPNGIsPerfect() async throws {
        let src = try Fixtures.write(Fixtures.uiLike(), to: dir.appendingPathComponent("ui.png"), type: .png)
        let info = try ImageProbe.probe(url: src)
        var s = Settings(); s.pngLossy = false
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: s, forceEncode: true)
        let out = dir.appendingPathComponent("ui-out.png")
        _ = try await ImageEncoder().encode(plan: plan, info: info, to: out)
        #expect(try score(src, out) >= 99.9)
    }

    @Test("lossy PNG on a screenshot-style image stays visually near-lossless")
    func lossyPNGFloor() async throws {
        let src = try Fixtures.write(Fixtures.uiLike(), to: dir.appendingPathComponent("ui2.png"), type: .png)
        let s = try score(src, try await optimise(src, mode: .balanced))
        #expect(s >= 70, "got \(s)")
    }

    // Minimum real-photo scores: HEIC balanced 80.8 / smallest 72.1.
    @Test("HEIC quality floors hold per mode", arguments: [(EncoderMode.balanced, 76.0), (.smallest, 66.0)])
    func heicFloors(mode: EncoderMode, floor: Double) async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1280, height: 960), to: dir.appendingPathComponent("h-\(mode.rawValue).heic"), type: .heic, quality: 0.97)
        let s = try score(src, try await optimise(src, mode: mode))
        #expect(s >= floor, "\(mode) scored \(s), below the floor \(floor)")
    }

    /// The oracle must actually be able to fail, otherwise it proves nothing.
    @Test("the oracle really does catch a visibly damaged image")
    func oracleCanFail() throws {
        let good = try Fixtures.write(Fixtures.photoLike(width: 640, height: 480), to: dir.appendingPathComponent("g.jpg"), type: .jpeg, quality: 0.95)
        let wreck = try Fixtures.write(Fixtures.photoLike(width: 640, height: 480), to: dir.appendingPathComponent("w.jpg"), type: .jpeg, quality: 0.02)
        let s = try score(good, wreck)
        #expect(s < 60, "a 2%-quality JPEG should score poorly; the oracle returned \(s)")
    }
}
