// EncodePlannerTests.swift - ImageInfo + Settings -> plan. Pure: no files, no encoders.

import Foundation
import Testing
@testable import ImageOptimizerCore

@Suite("EncodePlanner")
struct EncodePlannerTests {
    private let planner = EncodePlanner()
    private let source = URL(fileURLWithPath: "/tmp/io-plan/photo.jpg")

    private func fat(_ format: ImageFormat = .jpeg, bytes: Int64 = 4_000_000, mutate: (inout ImageInfo) -> Void = { _ in }) -> ImageInfo {
        var info = ImageInfo(format: format, width: 4000, height: 3000, fileSize: bytes)
        mutate(&info)
        return info
    }

    private func plan(_ info: ImageInfo, force: Bool = false, _ mutate: (inout Settings) -> Void = { _ in }) -> ImagePlan {
        var s = Settings()
        mutate(&s)
        return planner.plan(info: info, inputURL: source, settings: s, forceEncode: force)
    }

    // MARK: - JPEG

    @Test("balanced JPEG uses jpegli at distance 1.0")
    func balancedJPEG() {
        let p = plan(fat())
        #expect(p.outcome == .planned)
        #expect(p.steps == [.jpegli(distance: 1.0, chromaSubsampling: nil)])
        #expect(p.isLossless == false)
    }

    @Test("JPEG distance orders high quality < balanced < smallest")
    func jpegLadder() throws {
        func distance(_ mode: EncoderMode) throws -> Double {
            let p = plan(fat()) { $0.encoderMode = mode }
            guard case .jpegli(let d, _) = try #require(p.steps.first) else { throw NSError(domain: "x", code: 1) }
            return d
        }
        let (high, balanced, smallest) = (try distance(.highQuality), try distance(.balanced), try distance(.smallest))
        #expect(high < balanced && balanced < smallest, "lower distance = higher quality")
    }

    @Test("smallest mode subsamples chroma; the others leave it to the encoder")
    func chromaSubsampling() {
        #expect(plan(fat()) { $0.encoderMode = .smallest }.steps == [.jpegli(distance: 1.7, chromaSubsampling: "420")])
        #expect(plan(fat()) { $0.encoderMode = .balanced }.steps == [.jpegli(distance: 1.0, chromaSubsampling: nil)])
    }

    // MARK: - PNG

    @Test("balanced PNG is lossy pngquant then lossless oxipng")
    func balancedPNG() {
        let p = plan(fat(.png)) { $0.pngLossy = true }
        #expect(p.steps == [.pngquant(minQuality: 80, maxQuality: 98, speed: 3), .oxipng(level: 4)])
        #expect(p.isLossless == false)
    }

    @Test("with lossy PNG switched off, a PNG is only ever recompressed losslessly")
    func losslessPNG() {
        for mode in EncoderMode.allCases {
            let p = plan(fat(.png)) { $0.pngLossy = false; $0.encoderMode = mode }
            #expect(p.steps == [.oxipng(level: 4)], "mode \(mode)")
            #expect(p.isLossless)
        }
    }

    @Test("high quality mode never uses lossy palette reduction, even when allowed")
    func highQualityPNGIsLossless() {
        let p = plan(fat(.png)) { $0.encoderMode = .highQuality; $0.pngLossy = true }
        #expect(p.steps == [.oxipng(level: 4)])
        #expect(p.isLossless)
    }

    /// Real-data finding: a wider (lower-floor) range made PNGs no smaller but visibly worse.
    @Test("smallest PNG never accepts a lower quality floor than balanced")
    func smallestPNGDoesNotLowerTheFloor() throws {
        func floor(_ mode: EncoderMode) throws -> Int {
            guard case .pngquant(let lo, _, _) = try #require(plan(fat(.png)) { $0.encoderMode = mode }.steps.first) else { throw NSError(domain: "x", code: 1) }
            return lo
        }
        #expect(try floor(.smallest) >= floor(.balanced))
    }

    @Test("smallest PNG searches harder than balanced, rather than accepting more damage")
    func smallestPNGSearchesHarder() throws {
        func speedAndLevel(_ mode: EncoderMode) throws -> (Int, Int) {
            let steps = plan(fat(.png)) { $0.encoderMode = mode }.steps
            guard case .pngquant(_, _, let speed) = try #require(steps.first), case .oxipng(let level) = try #require(steps.last) else { throw NSError(domain: "x", code: 1) }
            return (speed, level)
        }
        let balanced = try speedAndLevel(.balanced), smallest = try speedAndLevel(.smallest)
        #expect(smallest.0 < balanced.0, "pngquant speed 1 is the slowest, best search")
        #expect(smallest.1 > balanced.1)
    }

    @Test("no planned PNG range falls below the floor the real-photo benchmark showed is safe (80)")
    func neverPlansTheDamagingRange() {
        for mode in EncoderMode.allCases {
            for step in plan(fat(.png)) { $0.encoderMode = mode }.steps {
                if case .pngquant(let lo, _, _) = step { #expect(lo >= 80, "min quality \(lo): the 60-85 and 70-95 ranges measured as visibly damaging") }
            }
        }
    }

    // MARK: - HEIC

    @Test("HEIC uses the Apple encoder, with quality ordered by mode")
    func heicLadder() throws {
        func quality(_ mode: EncoderMode) throws -> Double {
            guard case .heic(let q) = try #require(plan(fat(.heic)) { $0.encoderMode = mode }.steps.first) else { throw NSError(domain: "x", code: 1) }
            return q
        }
        #expect(try quality(.highQuality) > quality(.balanced))
        #expect(try quality(.balanced) > quality(.smallest))
    }

    // MARK: - Refusals that can never be overridden

    @Test("an animated image is refused as unsupported, even when forced")
    func animatedRefused() {
        for force in [false, true] {
            let p = plan(fat(.png) { $0.frameCount = 12 }, force: force)
            guard case .refused(.unsupported(let why)) = p.outcome else { Issue.record("force=\(force): expected unsupported"); continue }
            #expect(why.contains("Animated"))
            #expect(p.steps.isEmpty)
        }
    }

    @Test("CMYK is refused as unsupported, even when forced")
    func cmykRefused() {
        for force in [false, true] {
            guard case .refused(.unsupported) = plan(fat { $0.colorModel = .cmyk }, force: force).outcome else {
                Issue.record("force=\(force): expected unsupported"); continue
            }
        }
    }

    /// The benchmark's most dangerous finding: dropping the gain map looked like a 60% saving.
    @Test("an HDR gain-map image is refused, even when forced")
    func gainMapRefused() {
        for force in [false, true] {
            guard case .refused(.unsupported(let why)) = plan(fat(.heic) { $0.hasGainMap = true }, force: force).outcome else {
                Issue.record("force=\(force): expected unsupported"); continue
            }
            #expect(why.contains("HDR"))
        }
    }

    @Test("an enormous image is refused rather than exhausting memory")
    func hugeRefused() {
        let huge = ImageInfo(format: .jpeg, width: 20_000, height: 10_000, fileSize: 90_000_000)   // 200 MP
        guard case .refused(.unsupported) = plan(huge).outcome else { Issue.record("expected unsupported"); return }
    }

    // MARK: - The size guard, which CAN be overridden

    @Test("an already-squeezed JPEG is refused as overridable")
    func squeezedRefusedButOverridable() {
        guard case .refused(.alreadyEfficient) = plan(fat(bytes: 900_000)).outcome else {
            Issue.record("expected alreadyEfficient"); return
        }
    }

    @Test("forcing plans a real encode for a file the guard refused")
    func forceOverridesTheSizeGuard() {
        let p = plan(fat(bytes: 900_000), force: true)
        #expect(p.outcome == .planned)
        #expect(p.steps.isEmpty == false)
    }

    @Test("forcing does not change quality settings")
    func forceKeepsQuality() {
        let normal = plan(fat())
        let forced = plan(fat(), force: true)
        #expect(normal.steps == forced.steps)
    }

    // MARK: - Output

    @Test("the output keeps the source's format and extension")
    func outputKeepsExtension() {
        #expect(plan(fat()).outputURL.lastPathComponent == "photo_optimized.jpg")
        let upper = planner.plan(info: fat(.png), inputURL: URL(fileURLWithPath: "/tmp/SHOT.PNG"), settings: Settings())
        #expect(upper.outputURL.lastPathComponent == "SHOT_optimized.PNG")
    }

    @Test("the output never overwrites the source, even with an empty suffix")
    func outputNeverTheSource() {
        let p = plan(fat()) { $0.suffix = "" }
        #expect(p.outputURL.standardizedFileURL != source.standardizedFileURL)
    }
}

@Suite("EncodePlanner: portrait depth")
struct DepthRefusalTests {
    @Test("a portrait (depth) photo is refused as unsupported, even when forced")
    func depthRefused() {
        var info = ImageInfo(format: .heic, width: 4000, height: 3000, fileSize: 4_000_000)
        info.hasDepthData = true
        for force in [false, true] {
            let p = EncodePlanner().plan(info: info, inputURL: URL(fileURLWithPath: "/tmp/p.heic"), settings: Settings(), forceEncode: force)
            guard case .refused(.unsupported(let why)) = p.outcome else { Issue.record("force=\(force): expected unsupported"); continue }
            #expect(why.contains("depth"))
        }
    }
}
