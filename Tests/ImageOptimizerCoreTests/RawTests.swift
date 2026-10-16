// RawTests.swift - Camera RAW in, small JPEG out.
//
// The planning and naming rules need no file. The end-to-end tests use a real RAW found on the machine
// (see Requirements.rawSample) and skip when there is none.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("RAW planning", .serialized)
struct RawPlanningTests {
    private let planner = EncodePlanner()
    private let source = URL(fileURLWithPath: "/tmp/io-raw/IMG_2995.CR2")

    private func raw(_ mutate: (inout ImageInfo) -> Void = { _ in }) -> ImageInfo {
        var info = ImageInfo(format: .raw, width: 5472, height: 3648, bitDepth: 16, fileSize: 29_000_000)
        mutate(&info)
        return info
    }

    private func plan(_ info: ImageInfo, _ mutate: (inout Settings) -> Void = { _ in }) -> ImagePlan {
        var s = Settings(); mutate(&s)
        return planner.plan(info: info, inputURL: source, settings: s)
    }

    /// The distances were measured on 12 real RAWs; they sit lower than the JPEG ladder's because a RAW render still has all its detail.
    @Test("a RAW becomes a jpegli JPEG, with a tighter ladder than a JPEG source")
    func ladder() {
        #expect(plan(raw()) { $0.encoderMode = .highQuality }.steps == [.jpegli(distance: 0.3, chromaSubsampling: nil)])
        #expect(plan(raw()) { $0.encoderMode = .balanced }.steps == [.jpegli(distance: 0.7, chromaSubsampling: nil)])
        #expect(plan(raw()) { $0.encoderMode = .smallest }.steps == [.jpegli(distance: 1.7, chromaSubsampling: "420")])
    }

    @Test("a RAW is written as .jpg beside the source, never as its own format")
    func outputName() {
        let p = plan(raw())
        #expect(p.outputURL.lastPathComponent == "IMG_2995_optimized.jpg")
        #expect(p.outputURL.deletingLastPathComponent() == source.deletingLastPathComponent())
    }

    @Test("every RAW extension maps to .jpg", arguments: ["dng", "CR2", "cr3", "NEF", "arw", "raf", "orf", "rw2"])
    func extensions(ext: String) {
        let url = URL(fileURLWithPath: "/tmp/io-raw/IMG_0001.\(ext)")
        let p = planner.plan(info: raw(), inputURL: url, settings: Settings())
        #expect(p.outputURL.pathExtension == "jpg")
    }

    @Test("the camera's own JPEG of the same shot doesn't collide with the RAW's output")
    func noClashWithSiblingJPEG() {
        let sibling = source.deletingPathExtension().appendingPathExtension("JPG")
        #expect(plan(raw()).outputURL != sibling)
    }

    @Test("a RAW is never 'already optimised': it is not an encoded picture")
    func neverAlreadyEfficient() {
        #expect(BloatGuard.bppFloor(format: .raw, mode: .smallest) == nil)
        #expect(plan(raw { $0.fileSize = 3_000_000; $0.width = 6000; $0.height = 4000 }).outcome == .planned)
    }

    /// The HDR layer / depth map belong to the original, which a RAW conversion never touches.
    @Test("a RAW's HDR layer or depth map is not a reason to ask or refuse")
    func hdrAndDepthDontApply() {
        #expect(plan(raw { $0.hasGainMap = true; $0.hasDepthData = true }).outcome == .planned)
    }

    @Test("an enormous RAW is still refused rather than exhausting memory")
    func hugeRefused() {
        guard case .refused(.unsupported) = plan(raw { $0.width = 20_000; $0.height = 10_000 }).outcome else {
            Issue.record("expected unsupported"); return
        }
    }

    @Test("RAW needs only the JPEG encoder")
    func tools() { #expect(ToolLocator.tools(for: .raw) == [.cjpegli]) }
}

@Suite("RAW end to end", .serialized, .timeLimit(.minutes(5)),
       .enabled(if: Requirements.rawAvailable && Requirements.jpegli))
final class RawEndToEndTests {
    private let dir: URL
    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    private func copyOfSample() throws -> URL {
        let sample = try #require(Requirements.rawSample)
        let copy = dir.appendingPathComponent(sample.lastPathComponent)
        try FileManager.default.copyItem(at: sample, to: copy)
        return copy
    }

    private func waitUntilIdle(_ queue: JobQueue) async -> [Job] {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await queue.isIdle { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await queue.snapshot()
    }

    @Test("the probe recognises a real RAW and reports its true size")
    func probes() throws {
        let info = try ImageProbe.probe(url: try copyOfSample())
        #expect(info.format == .raw)
        #expect(info.width > 1000 && info.height > 1000)
        #expect(info.frameCount == 1)
    }

    @Test("a real RAW becomes a much smaller, upright JPEG with its colour profile and, with everything ticked, no metadata")
    func developsToJPEG() async throws {
        let src = try copyOfSample()
        let info = try ImageProbe.probe(url: src)
        var everything = Settings(); everything.removeMetadata = Set(MetadataCategory.allCases)
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: everything)
        #expect(plan.outcome == .planned)
        let out = dir.appendingPathComponent("out.jpg")
        _ = try await ImageEncoder().encode(plan: plan, info: info, to: out)

        // It is a JPEG, far smaller than the RAW.
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let outSize = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        #expect(outSize > 0 && outSize < info.fileSize / 5)

        // Upright exactly once: stored pixels already rotated, no orientation tag left to apply again.
        let props = Fixtures.properties(out)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == info.displayWidth)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == info.displayHeight)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)

        // Wide-gamut colour is kept and labelled; nothing identifying the camera or place survives.
        #expect((props[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil && tiff?[kCGImagePropertyTIFFModel] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }

    @Test("by default a RAW's JPEG keeps its camera details but never the location")
    func defaultKeepsDetailsDropsLocation() async throws {
        let src = try copyOfSample()
        let info = try ImageProbe.probe(url: src)
        let srcProps = Fixtures.properties(src)
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: Settings())
        let out = dir.appendingPathComponent("meta.jpg")
        _ = try await ImageEncoder().encode(plan: plan, info: info, to: out)
        let props = Fixtures.properties(out)
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "the location must not survive by default")
        let before = (srcProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel]
        let after = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel]
        #expect(before == nil || after != nil, "the camera model the RAW carries is kept")
        // Upright exactly once, whatever was copied.
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == info.displayWidth)
    }

    @Test("the JPEG looks like the developed RAW (measured, not assumed)", .enabled(if: Requirements.oracle))
    func looksLikeTheRAW() async throws {
        let src = try copyOfSample()
        let info = try ImageProbe.probe(url: src)
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: Settings())
        let out = dir.appendingPathComponent("out.jpg")
        _ = try await ImageEncoder().encode(plan: plan, info: info, to: out)

        // Reference: the same development, kept lossless.
        let px = try PixelExtractor.extractRAW(url: src)
        let rgba = Data((0..<px.width * px.height).flatMap { i in [px.bytes[i * 3], px.bytes[i * 3 + 1], px.bytes[i * 3 + 2], 255] })
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let provider = try #require(CGDataProvider(data: rgba as CFData))
        let image = try #require(CGImage(
            width: px.width, height: px.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px.width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let reference = try Fixtures.write(image, to: dir.appendingPathComponent("ref.png"), type: .png)
        let score = try #require(Fixtures.perceptualScore(reference: reference, candidate: out, scratch: dir))
        // Measured on 33 real RAWs at Balanced: min 80.3, median 85.2.
        #expect(score >= 78, "ssimulacra2 \(score)")
    }

    @Test("converting a RAW never moves the RAW to the Trash, even with 'delete originals' on")
    func rawIsNeverTrashed() async throws {
        let src = try copyOfSample()
        var settings = Settings(); settings.deleteSource = true
        let queue = JobQueue(maxConcurrent: 1, settings: settings)
        await queue.addJob(url: src)
        let jobs = await waitUntilIdle(queue)
        #expect(jobs.first?.state == .succeeded, "\(jobs.first?.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: src.path), "the RAW negative was deleted")
        #expect(jobs.first?.resultURL?.pathExtension == "jpg")
    }

    @Test("a file that merely has a RAW name fails clearly instead of crashing")
    func garbageRAW() async throws {
        let fake = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: fake)
        let queue = JobQueue(maxConcurrent: 1, settings: Settings())
        await queue.addJob(url: fake)
        let job = try #require(await waitUntilIdle(queue).first)
        #expect(job.state == .failed || job.state == .unsupported)
        #expect(!job.error.isEmpty)
    }
}
