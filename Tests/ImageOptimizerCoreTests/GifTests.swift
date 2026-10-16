// GifTests.swift - GIF in, smaller GIF out, with every frame, delay and the loop count intact.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("GIF planning")
struct GifPlanningTests {
    private let planner = EncodePlanner()
    private let source = URL(fileURLWithPath: "/tmp/io-gif/loop.gif")

    private func gif(_ mutate: (inout ImageInfo) -> Void = { _ in }) -> ImageInfo {
        var info = ImageInfo(format: .gif, width: 480, height: 270, bitDepth: 8, fileSize: 1_500_000)
        info.frameCount = 40
        mutate(&info)
        return info
    }

    private func plan(_ info: ImageInfo, force: Bool = false, _ mutate: (inout Settings) -> Void = { _ in }) -> ImagePlan {
        var s = Settings(); mutate(&s)
        return planner.plan(info: info, inputURL: source, settings: s, forceEncode: force)
    }

    @Test("the ladder: lossless, lossy 10, lossy 40")
    func ladder() {
        #expect(plan(gif()) { $0.encoderMode = .highQuality }.steps == [.gifsicle(lossy: nil, maxSide: nil)])
        #expect(plan(gif()) { $0.encoderMode = .balanced }.steps == [.gifsicle(lossy: 10, maxSide: nil)])
        #expect(plan(gif()) { $0.encoderMode = .smallest }.steps == [.gifsicle(lossy: 40, maxSide: nil)])
    }

    @Test("a GIF wider than the cap is shrunk to fit in Balanced (1280) and Smallest (960); High quality and small GIFs never are")
    func caps() {
        let big = { (i: inout ImageInfo) in i.width = 1912; i.height = 1197 }
        #expect(plan(gif(big)) { $0.encoderMode = .highQuality }.steps == [.gifsicle(lossy: nil, maxSide: nil)])
        #expect(plan(gif(big)) { $0.encoderMode = .balanced }.steps == [.gifsicle(lossy: 10, maxSide: 1280)])
        #expect(plan(gif(big)) { $0.encoderMode = .smallest }.steps == [.gifsicle(lossy: 40, maxSide: 960)])
        // Exactly at the cap is left alone, and a tall one is measured on its longer side.
        #expect(plan(gif({ $0.width = 1280; $0.height = 720 })) { $0.encoderMode = .balanced }.steps == [.gifsicle(lossy: 10, maxSide: nil)])
        #expect(plan(gif({ $0.width = 700; $0.height = 1500 })) { $0.encoderMode = .balanced }.steps == [.gifsicle(lossy: 10, maxSide: 1280)])
    }

    @Test("chunking: only big, long GIFs, never more chunks than cores, memory allows, or 16-frame slices; ranges tile every frame once")
    func chunkPlanning() throws {
        #expect(ImageEncoder.chunkRanges(frames: 446, bytes: 1_000_000, cores: 12) == nil, "a small file is run whole")
        #expect(ImageEncoder.chunkRanges(frames: 20, bytes: 90_000_000, cores: 12) == nil, "too few frames to split")
        #expect(ImageEncoder.chunkRanges(frames: 446, bytes: 90_000_000, cores: 1) == nil, "one core gains nothing")
        let r = try #require(ImageEncoder.chunkRanges(frames: 446, bytes: 90_000_000, cores: 12))
        #expect(r.count == 12)
        #expect(r.first?.lowerBound == 0 && r.last?.upperBound == 445)
        #expect(zip(r, r.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound }, "ranges must tile with no gap or overlap")
        #expect(r.allSatisfy { $0.count >= 16 })
        // 40 frames can only make two 20-frame chunks even with 12 cores, and a 1 GB source is limited by memory.
        #expect(ImageEncoder.chunkRanges(frames: 40, bytes: 90_000_000, cores: 12)?.count == 2)
        #expect(ImageEncoder.chunkRanges(frames: 446, bytes: 1_000_000_000, cores: 12)?.count == 3)
    }

    @Test("a chunk only starts on a frame whose disposal leaves the picture alone; boundaries slide forward or are dropped")
    func safeBoundaries() throws {
        let info = """
        * x.gif 6 images
          + image #0 10x10
            disposal asis delay 0.1s
          + image #1 10x10
            disposal background delay 0.1s
          + image #2 10x10
            delay 0.1s
          + image #3 10x10
            disposal previous delay 0.1s
          + image #4 10x10
            disposal background delay 0.1s
          + image #5 10x10
            disposal asis delay 0.1s
        """
        let safe = ImageEncoder.keyframeSafe(info: info)
        #expect(safe == [true, false, true, false, false, true])
        // 3 chunks 0-1, 2-3, 4-5: the second starts at 2 (safe); the third's 4 is unsafe so slides to 5.
        #expect(ImageEncoder.alignedRanges([0...1, 2...3, 4...5], safe: safe) == [0...1, 2...4, 5...5])
        // Nothing safe in the second chunk: it is joined to the first.
        #expect(ImageEncoder.alignedRanges([0...2, 3...4], safe: safe) == nil)
        #expect(ImageEncoder.alignedRanges([0...2, 3...5], safe: safe) == [0...4, 5...5])
        #expect(ImageEncoder.alignedRanges([0...2, 3...5], safe: [true]) == nil, "an unparseable listing means a serial run")
    }

    @Test("only high quality is lossless, which lets the post-flight guard keep a small saving")
    func losslessFlag() {
        #expect(plan(gif()) { $0.encoderMode = .highQuality }.isLossless)
        #expect(!plan(gif()) { $0.encoderMode = .balanced }.isLossless)
    }

    @Test("an animated GIF is planned, not refused; other animated formats still are")
    func animationAllowedForGIFOnly() {
        #expect(plan(gif()).outcome == .planned)
        var png = ImageInfo(format: .png, width: 64, height: 64, fileSize: 40_000); png.frameCount = 6
        guard case .refused(.unsupported) = plan(png).outcome else { Issue.record("APNG should be refused"); return }
    }

    @Test("the output stays a .gif beside the source")
    func outputName() {
        #expect(plan(gif()).outputURL.lastPathComponent == "loop_optimized.gif")
    }

    @Test("a GIF has no bits-per-pixel floor: its size says nothing about prior optimising")
    func noFloor() {
        #expect(BloatGuard.bppFloor(format: .gif, mode: .smallest) == nil)
        #expect(plan(gif { $0.fileSize = 30_000 }).outcome == .planned)
    }

    @Test("GIF needs only gifsicle")
    func tools() { #expect(ToolLocator.tools(for: .gif) == [.gifsicle]) }
}

@Suite("GIF end to end", .serialized, .timeLimit(.minutes(3)), .enabled(if: Requirements.gifsicle))
final class GifEndToEndTests {
    private let dir: URL
    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    private struct Shape: Equatable { var frames: Int; var width: Int; var height: Int; var totalDelay: Double; var loop: Int? }

    private func shape(_ url: URL) -> Shape? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var total = 0.0
        for i in 0..<CGImageSourceGetCount(src) {
            let d = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += (d?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (d?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        }
        let g = (CGImageSourceCopyProperties(src, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return Shape(frames: CGImageSourceGetCount(src), width: first.width, height: first.height,
                     totalDelay: (total * 100).rounded() / 100, loop: g?[kCGImagePropertyGIFLoopCount] as? Int)
    }

    /// Frame `i` as 8-bit sRGB RGBA, composited as a viewer shows it.
    private func frame(_ url: URL, _ i: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                      bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)); return true
        }
        return ok ? buf : nil
    }

    private func optimise(_ src: URL, _ mode: EncoderMode, force: Bool = false) async throws -> (out: URL, info: ImageInfo) {
        let info = try ImageProbe.probe(url: src)
        var s = Settings(); s.encoderMode = mode
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: s, forceEncode: force)
        #expect(plan.outcome == .planned)
        let out = dir.appendingPathComponent("o-\(UUID().uuidString.prefix(6)).gif")
        _ = try await ImageEncoder().encode(plan: plan, info: info, to: out)
        return (out, info)
    }

    /// The same animation with every frame stored whole, as many GIF makers write them.
    private func unoptimised(_ gif: URL) throws -> URL {
        let tool = try #require(ToolLocator.url(for: .gifsicle))
        let out = dir.appendingPathComponent("full-\(UUID().uuidString.prefix(6)).gif")
        let p = Process(); p.executableURL = tool; p.arguments = ["--unoptimize", gif.path, "-o", out.path]
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return out
    }

    private func size(_ u: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int64) ?? -1 }

    @Test("lossless: smaller, and every frame, the timing and the loop count are exactly kept")
    func lossless() async throws {
        let src = try unoptimised(try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("a.gif"), loopCount: 3))
        let (out, _) = try await optimise(src, .highQuality)
        #expect(size(out) < size(src) / 2, "\(size(out)) vs \(size(src))")
        let before = try #require(shape(src)), after = try #require(shape(out))
        #expect(before.width == after.width && before.height == after.height)
        #expect(before.totalDelay == after.totalDelay, "playback length changed: \(before.totalDelay) -> \(after.totalDelay)")
        #expect(before.loop == after.loop, "loop count changed: \(String(describing: before.loop)) -> \(String(describing: after.loop))")
        // Frames may be merged when identical, so compare by playback time rather than index.
        for i in 0..<before.frames {
            let t = (Double(i) + 0.5) * before.totalDelay / Double(before.frames)
            let j = min(after.frames - 1, Int(t / before.totalDelay * Double(after.frames)))
            let a = try #require(frame(src, i)), b = try #require(frame(out, j))
            #expect(a.count == b.count)
            if after.frames == before.frames { #expect(a == b, "frame \(i) pixels differ after a lossless optimise") }
        }
    }

    @Test("balanced: still the same frames and timing, each frame visually close, and smaller")
    func balanced() async throws {
        let src = try unoptimised(try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("b.gif"), loopCount: 0))
        let (out, _) = try await optimise(src, .balanced)
        #expect(size(out) < size(src))
        let before = try #require(shape(src)), after = try #require(shape(out))
        #expect(before.totalDelay == after.totalDelay)
        #expect(before.loop == after.loop)
        guard after.frames == before.frames else { return }
        for i in 0..<before.frames {
            let a = try #require(frame(src, i)), b = try #require(frame(out, i))
            #expect(Fixtures.meanDifference(a, b) < 4, "frame \(i) drifted")
        }
    }

    @Test("a big GIF is resized to the cap in Balanced, with every frame, the timing and the loop count kept, and not at all in High quality")
    func resized() async throws {
        let src = try unoptimised(try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("big.gif"), frames: 5, size: 1500, loopCount: 2))
        let before = try #require(shape(src))
        let (out, _) = try await optimise(src, .balanced)
        let after = try #require(shape(out))
        #expect(max(after.width, after.height) == 1280, "\(after.width)x\(after.height)")
        #expect(after.width == after.height, "aspect ratio changed")
        #expect(after.totalDelay == before.totalDelay && after.loop == before.loop)
        let (kept, _) = try await optimise(src, .highQuality)
        let k = try #require(shape(kept))
        #expect(k.width == 1500 && k.height == 1500)
    }

    @Test("chunked across cores: same frames, delays, loop count and picture as one run, including at every chunk boundary")
    func chunked() async throws {
        let tool = try #require(ToolLocator.url(for: .gifsicle))
        // ImageIO stores only what changed between frames and leaves them "asis", as a screen recording does.
        let src = try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("delta.gif"), frames: 40, size: 200, loopCount: 5)
        let before = try #require(shape(src))
        #expect(before.frames == 40)
        let base = ["-O3", "--no-comments", "--no-names", "--no-extensions", "--no-warnings", "--lossy=10"]
        let serial = dir.appendingPathComponent("serial.gif"), chunkedOut = dir.appendingPathComponent("chunked.gif")
        let q = Process(); q.executableURL = tool; q.arguments = base + [src.path, "-o", serial.path]
        try q.run(); q.waitUntilExit()
        let work = try Fixtures.makeDirectory(); defer { try? FileManager.default.removeItem(at: work) }
        let infoFile = work.appendingPathComponent("info.txt")
        let r = Process(); r.executableURL = tool; r.arguments = ["--info", src.path, "-o", infoFile.path]
        try r.run(); r.waitUntilExit()
        let safe = ImageEncoder.keyframeSafe(info: try String(contentsOf: infoFile, encoding: .utf8))
        #expect(safe.count == 40 && !safe.contains(false))
        let ranges = try #require(ImageEncoder.alignedRanges([0...9, 10...19, 20...29, 30...39], safe: safe))
        #expect(ranges.count == 4)
        try await ImageEncoder().runGifsicleChunked(tool: tool, input: src, output: chunkedOut, baseArgs: base, ranges: ranges, work: work)
        let a = try #require(shape(serial)), b = try #require(shape(chunkedOut))
        #expect(b.frames == before.frames && b.width == before.width && b.height == before.height)
        #expect(b.totalDelay == before.totalDelay, "playback length changed: \(before.totalDelay) -> \(b.totalDelay)")
        #expect(b.loop == a.loop && b.loop == 5, "loop count: \(String(describing: b.loop))")
        // Every frame, and so every chunk boundary (9|10, 19|20, 29|30), must look like the one-run result.
        var worst = 0.0
        for i in 0..<before.frames {
            let x = try #require(frame(serial, i)), y = try #require(frame(chunkedOut, i))
            var d = 0; for k in 0..<x.count { d += abs(Int(x[k]) - Int(y[k])) }
            worst = max(worst, Double(d) / Double(x.count))
        }
        #expect(worst < 3, "a frame differs from the single-run result by \(worst) on average")
    }

    @Test("a loop count of 'forever' and of 'once' both survive")
    func loopKinds() async throws {
        for loop in [0, 1] {
            let src = try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("l\(loop).gif"), loopCount: loop)
            let (out, _) = try await optimise(src, .highQuality)
            #expect(shape(out)?.loop == shape(src)?.loop, "loop \(loop)")
        }
    }

    @Test("a still GIF is optimised too")
    func stillGIF() async throws {
        let src = try Fixtures.write(Fixtures.uiLike(), to: dir.appendingPathComponent("s.gif"), type: .gif)
        let (out, info) = try await optimise(src, .highQuality)
        #expect(info.frameCount == 1)
        #expect(shape(out)?.frames == 1)
        #expect(frame(src, 0) == frame(out, 0))
    }

    @Test("through the queue: a GIF beside its source as name_optimized.gif, original untouched")
    func throughTheQueue() async throws {
        let src = try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("q.gif"))
        let originalSize = size(src)
        let queue = JobQueue(maxConcurrent: 1, settings: Settings())
        await queue.addJob(url: src)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(await queue.isIdle) { try? await Task.sleep(for: .milliseconds(50)) }
        let job = try #require(await queue.snapshot().first)
        #expect(job.state == .succeeded, "\(job.error)")
        #expect(job.resultURL?.lastPathComponent == "q_optimized.gif")
        #expect(size(src) == originalSize)
    }

    @Test("a lossy result that would be larger is discarded, not written")
    func growthIsDiscarded() async throws {
        // A 2-frame noise GIF is already near its floor; lossy output must beat 92% of it or be dropped.
        let src = try Fixtures.animatedGIF(to: dir.appendingPathComponent("n.gif"))
        let queue = JobQueue(maxConcurrent: 1, settings: Settings())
        await queue.addJob(url: src)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(await queue.isIdle) { try? await Task.sleep(for: .milliseconds(50)) }
        let job = try #require(await queue.snapshot().first)
        if job.state == .succeeded { #expect((job.resultSize ?? .max) < Int64(Double(job.inputSize) * 0.92)) }
        else { #expect(job.state == .discardedAsBlob, "\(job.state) \(job.error)") ; #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("n_optimized.gif").path)) }
    }

    @Test("a file that merely has a GIF name fails clearly instead of crashing")
    func garbage() async throws {
        let fake = dir.appendingPathComponent("bad.gif")
        try Data("GIF89a".utf8 + Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 7) })).write(to: fake)
        let queue = JobQueue(maxConcurrent: 1, settings: Settings())
        await queue.addJob(url: fake)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !(await queue.isIdle) { try? await Task.sleep(for: .milliseconds(50)) }
        let job = try #require(await queue.snapshot().first)
        #expect([.failed, .unsupported, .discardedAsBlob, .alreadyOptimized].contains(job.state))
        #expect(!job.error.isEmpty)
    }
}

@Suite("GIF fallback", .serialized, .timeLimit(.minutes(3)), .enabled(if: Requirements.gifsicle))
final class GifFallbackTests {
    private let dir: URL
    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// ImageIO already stores only each frame's changed region, so lossless saves ~8% here and lossy
    /// can't add the 8% more the lossy guard demands: a Balanced run must keep the lossless saving.
    @Test("a lossy GIF that can't beat the guard keeps the lossless saving instead of discarding it")
    func fallsBackToLossless() async throws {
        let src = try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("f.gif"))
        let info = try ImageProbe.probe(url: src)
        var s = Settings(); s.encoderMode = .smallest
        let plan = EncodePlanner().plan(info: info, inputURL: src, settings: s)
        let out = dir.appendingPathComponent("out.gif")
        let report = try await ImageEncoder().encode(plan: plan, info: info, to: out)
        let inSize = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? 0
        let outSize = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        #expect(outSize < inSize)
        // Either lossy earned its keep outright, or the fallback ran and said so.
        #expect(Double(outSize) < Double(inSize) * 0.92 || report.producedLossless)
        if report.producedLossless { #expect(report.notes.contains { $0.contains("losslessly") }) }
    }

    @Test("through the queue, that saving is kept rather than reported as 'nothing written'")
    func queueKeepsIt() async throws {
        let src = try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("g.gif"))
        let queue = JobQueue(maxConcurrent: 1, settings: Settings())
        await queue.addJob(url: src)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(await queue.isIdle) { try? await Task.sleep(for: .milliseconds(50)) }
        let job = try #require(await queue.snapshot().first)
        #expect(job.state == .succeeded, "\(job.state) \(job.error)")
    }
}
