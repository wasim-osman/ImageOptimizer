// ImageEncoderTests.swift - The REAL encoders (cjpegli, oxipng, pngquant, Apple HEIC) against
// real files. No stubs: these assert that an optimised image still looks the same and still
// carries what it must, which is the entire point of the app.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("ImageEncoder", .serialized, .timeLimit(.minutes(3)))
final class ImageEncoderTests {
    private let dir: URL
    private let encoder = ImageEncoder()

    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Plans with force so a small synthetic fixture isn't refused by the size guard; the
    /// encoder, not the guard, is what's under test here.
    private func encode(_ url: URL, mode: EncoderMode = .balanced, pngLossy: Bool = true) async throws -> (out: URL, info: ImageInfo, report: EncodeReport) {
        let info = try ImageProbe.probe(url: url)
        var s = Settings(); s.encoderMode = mode; s.pngLossy = pngLossy
        let plan = EncodePlanner().plan(info: info, inputURL: url, settings: s, forceEncode: true)
        guard case .planned = plan.outcome else { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "not planned: \(plan.outcome)"]) }
        let out = dir.appendingPathComponent("out-\(UUID().uuidString.prefix(6)).\(url.pathExtension)")
        let report = try await encoder.encode(plan: plan, info: info, to: out)
        return (out, info, report)
    }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? -1
    }

    // MARK: - JPEG

    @Test("a JPEG gets smaller and still looks the same", .enabled(if: Requirements.jpegli))
    func jpegShrinksAndLooksTheSame() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1024, height: 768), to: dir.appendingPathComponent("p.jpg"), type: .jpeg, quality: 0.97)
        let (out, _, _) = try await encode(src)
        #expect(size(of: out) < size(of: src))
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(a.width == b.width && a.height == b.height)
        #expect(Fixtures.meanDifference(a.rgba, b.rgba) < 4, "the optimised JPEG must look like the original")
    }

    /// The trap that made 7 of 8 real iPhone photos display sideways in the benchmark.
    @Test("a rotated JPEG still DISPLAYS upright after optimising, for every EXIF orientation",
          .enabled(if: Requirements.jpegli), arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func orientationSurvives(tag: Int) async throws {
        let src = try Fixtures.write(Fixtures.cornerMarkers(), to: dir.appendingPathComponent("o\(tag).jpg"), type: .jpeg,
                                     quality: 1.0, orientation: tag)
        let (out, _, _) = try await encode(src, mode: .highQuality)
        let before = try #require(Fixtures.viewerPixels(src)), after = try #require(Fixtures.viewerPixels(out))
        #expect(before.width == after.width && before.height == after.height,
                "orientation \(tag): displayed size changed \(before.width)x\(before.height) -> \(after.width)x\(after.height)")
        #expect(Fixtures.meanDifference(before.rgba, after.rgba) < 6,
                "orientation \(tag): the photo no longer looks like the original — it would display rotated")
    }

    @Test("a Display P3 JPEG keeps its profile and its colours", .enabled(if: Requirements.jpegli))
    func displayP3Survives() async throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = try Fixtures.write(Fixtures.photoLike(width: 640, height: 480, colorSpace: p3), to: dir.appendingPathComponent("p3.jpg"), type: .jpeg, quality: 0.97)
        let (out, _, _) = try await encode(src)
        #expect(try ImageProbe.probe(url: out).iccProfileName == "Display P3", "dropping the profile washes the colours out")
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(Fixtures.meanDifference(a.rgba, b.rgba) < 4, "colours must match when both are shown colour-managed")
    }

    @Test("an sRGB JPEG doesn't gain a pointless embedded profile", .enabled(if: Requirements.jpegli))
    func srgbStaysUntagged() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(), to: dir.appendingPathComponent("s.jpg"), type: .jpeg, quality: 0.95)
        let (out, _, _) = try await encode(src)
        #expect(try ImageProbe.probe(url: out).iccProfileName == nil || ImageProbe.probe(url: out).isPlainSRGB)
    }

    @Test("a greyscale JPEG stays greyscale, rather than ballooning into RGB", .enabled(if: Requirements.jpegli))
    func grayscaleStaysGray() async throws {
        let src = try Fixtures.write(Fixtures.grayscale(), to: dir.appendingPathComponent("g.jpg"), type: .jpeg, quality: 0.97)
        let (out, _, _) = try await encode(src)
        #expect(try ImageProbe.probe(url: out).colorModel == .gray)
    }

    @Test("camera metadata is stripped from a JPEG: no EXIF capture details, no GPS", .enabled(if: Requirements.jpegli))
    func jpegMetadataStripped() async throws {
        let src = try Fixtures.writeWithCameraMetadata(Fixtures.photoLike(), to: dir.appendingPathComponent("m.jpg"), type: .jpeg)
        let before = Fixtures.properties(src)
        #expect(before[kCGImagePropertyGPSDictionary] != nil, "precondition: the fixture really carries GPS")
        let (out, _, _) = try await encode(src)
        let after = Fixtures.properties(out)
        #expect(after[kCGImagePropertyGPSDictionary] == nil, "the location must not survive")
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "capture time must not survive")
        #expect((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil, "camera model must not survive")
    }

    // MARK: - PNG

    @Test("lossless PNG recompression is pixel-exact and keeps the colour profile", .enabled(if: Requirements.png))
    func losslessPNGIsExact() async throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = try Fixtures.write(Fixtures.photoLike(colorSpace: p3), to: dir.appendingPathComponent("l.png"), type: .png)
        let (out, _, _) = try await encode(src, pngLossy: false)
        #expect(try ImageProbe.probe(url: out).iccProfileName == "Display P3", "oxipng must run with --strip safe")
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(a.rgba == b.rgba, "'lossless' means every pixel identical — verified, not assumed")
    }

    @Test("lossless recompression keeps 16-bit alpha exactly", .enabled(if: Requirements.png))
    func sixteenBitAlphaExact() async throws {
        let src = try Fixtures.write(Fixtures.sixteenBitWithAlpha(), to: dir.appendingPathComponent("a16.png"), type: .png)
        let (out, _, _) = try await encode(src, pngLossy: false)
        let info = try ImageProbe.probe(url: out)
        #expect(info.hasAlpha && info.bitDepth == 16)
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(a.rgba == b.rgba)
    }

    /// pngquant drops the profile tag, which is only safe if it first CONVERTS to sRGB. That
    /// needs lcms2 compiled in. A build without it shifts every wide-gamut PNG's colours (mean
    /// error ~7 instead of ~0), so this test guards the packaging step.
    @Test("lossy PNG on a Display P3 image converts colours instead of just dropping the tag", .enabled(if: Requirements.png))
    func pngquantConvertsColour() async throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = try Fixtures.write(Fixtures.photoLike(width: 256, height: 256, colorSpace: p3), to: dir.appendingPathComponent("q.png"), type: .png)
        let (out, _, _) = try await encode(src, pngLossy: true)
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(Fixtures.meanDifference(a.rgba, b.rgba) < 3,
                "a large error means pngquant was built without colour management and is shifting colours")
    }

    @Test("lossy PNG roughly halves a screenshot-style image", .enabled(if: Requirements.png))
    func lossyPNGShrinksUI() async throws {
        let src = try Fixtures.write(Fixtures.uiLike(), to: dir.appendingPathComponent("ui.png"), type: .png)
        let (out, _, _) = try await encode(src, pngLossy: true)
        #expect(size(of: out) < size(of: src) / 2, "\(size(of: src)) -> \(size(of: out))")
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(Fixtures.meanDifference(a.rgba, b.rgba) < 2, "and it must still look the same")
    }

    /// Photographic noise is the worst case for a palette. The bar here is only that the encoder
    /// stays valid and never makes the file bigger.
    @Test("lossy PNG never grows even a pathological noisy photo", .enabled(if: Requirements.png))
    func lossyPNGNeverGrows() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 512, height: 512), to: dir.appendingPathComponent("big.png"), type: .png)
        let (out, _, _) = try await encode(src, pngLossy: true)
        #expect(size(of: out) <= size(of: src), "\(size(of: src)) -> \(size(of: out))")
    }

    @Test("a PNG pngquant can't improve falls back to lossless instead of failing", .enabled(if: Requirements.png))
    func pngquantSkipFallsBack() async throws {
        // Pure noise can't hit the quality floor, so pngquant exits 99 and must be skipped.
        var rng = Fixtures.SeededRandom(state: 99)
        var px = [UInt8](repeating: 255, count: 128 * 128 * 4)
        for i in 0..<px.count where i % 4 != 3 { px[i] = rng.next() }
        let ctx = CGContext(data: &px, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let src = try Fixtures.write(ctx.makeImage()!, to: dir.appendingPathComponent("noise.png"), type: .png)
        let (out, _, report) = try await encode(src, pngLossy: true)
        #expect(FileManager.default.fileExists(atPath: out.path), "the result must still be written")
        #expect(report.notes.contains { $0.contains("lossless") }, "the user should be told it fell back; got \(report.notes)")
        let a = try #require(Fixtures.viewerPixels(src)), b = try #require(Fixtures.viewerPixels(out))
        #expect(a.rgba == b.rgba, "a fallback to lossless must be pixel-exact")
    }

    // MARK: - HEIC

    @Test("a HEIC keeps its orientation after optimising")
    func heicOrientation() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 800, height: 600), to: dir.appendingPathComponent("h.heic"), type: .heic, quality: 0.95, orientation: 6)
        #expect(try ImageProbe.probe(url: src).orientation == 6, "precondition")
        let (out, _, _) = try await encode(src)
        #expect(try ImageProbe.probe(url: out).orientation == 6, "a bitmap re-encode dropped this on 7 of 8 real iPhone photos")
    }

    @Test("a HEIC keeps its Display P3 profile")
    func heicProfile() async throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = try Fixtures.write(Fixtures.photoLike(width: 640, height: 480, colorSpace: p3), to: dir.appendingPathComponent("hp.heic"), type: .heic, quality: 0.95)
        let (out, _, _) = try await encode(src)
        #expect(try ImageProbe.probe(url: out).iccProfileName == "Display P3")
    }

    @Test("HEIC metadata policy: GPS and capture details are stripped, orientation kept")
    func heicMetadataStripped() async throws {
        let src = try Fixtures.writeWithCameraMetadata(Fixtures.photoLike(width: 800, height: 600), to: dir.appendingPathComponent("hm.heic"),
                                                       type: .heic, quality: 0.95, orientation: 6)
        #expect(Fixtures.properties(src)[kCGImagePropertyGPSDictionary] != nil, "precondition: fixture carries GPS")
        let (out, _, _) = try await encode(src)
        let after = Fixtures.properties(out)
        #expect(after[kCGImagePropertyGPSDictionary] == nil, "the location must not survive")
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil, "capture time must not survive")
        #expect((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil, "camera model must not survive")
        #expect(after[kCGImagePropertyOrientation] as? Int == 6, "orientation is essential and must survive")
    }

    // MARK: - Cancellation

    @Test("cancelling kills a running tool promptly")
    func cancelKillsTheProcess() async throws {
        let task = Task { await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(400))
        let started = Date()
        task.cancel()
        let result = await task.value
        #expect(result.wasCancelled)
        #expect(Date().timeIntervalSince(started) < 3, "cancel must not wait out a 30-second process")
    }

    @Test("a cancel that lands before launch is honoured, not lost")
    func cancelBeforeLaunch() async {
        let task = Task { await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        task.cancel()
        let started = Date()
        let result = await task.value
        #expect(result.wasCancelled)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("a tool that exits before reading its input doesn't crash the app with SIGPIPE")
    func earlyExitDoesNotCrash() async {
        let result = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: []) { handle in
            let big = Data(repeating: 0, count: 1 << 20)
            for _ in 0..<8 { try handle.write(contentsOf: big) }
        }
        #expect(result.exitCode == 0)
    }

    @Test("a missing tool is reported as such, not a crash")
    func missingToolReported() async {
        let result = await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("couldn't launch"))
    }
}
