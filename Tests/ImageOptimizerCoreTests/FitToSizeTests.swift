// FitToSizeTests.swift - "Fit to size": the search, the planning, and real files shrunk under a limit.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("Fit to size: the side search")
struct FitSideTests {
    /// A made-up encoder whose size follows side^1.7, like a GIF's.
    private func model(_ k: Double, exponent: Double = 1.7, calls: UnsafeMutablePointer<[Int]>) -> (Int) async throws -> Int64 {
        { side in calls.pointee.append(side); return Int64(k * pow(Double(side), exponent)) }
    }

    @Test("it lands under the target, close to it, in a handful of trials", arguments: [2.0, 7.0, 40.0])
    func converges(ratio: Double) async throws {
        var calls: [Int] = []
        let target: Int64 = 10_000_000
        let k = Double(target) * ratio / pow(2000, 1.7)        // full size is `ratio` times too big
        let start = Int(2000 * pow(1 / ratio * 0.93, 1 / 1.7))
        let best = try await ImageEncoder.fitSide(start: start, floor: 100, ceiling: 2000, target: target, minFill: 0.8,
                                                  trial: model(k, calls: &calls))
        let fit = try #require(best)
        #expect(fit.bytes <= target)
        #expect(Double(fit.bytes) >= 0.8 * Double(target), "shouldn't shrink more than needed")
        #expect(calls.count <= 6, "took \(calls.count) trials: \(calls)")
    }

    @Test("a file that already fits at full size stops there and is never enlarged")
    func ceiling() async throws {
        var calls: [Int] = []
        let best = try await ImageEncoder.fitSide(start: 800, floor: 100, ceiling: 800, target: 10_000_000, minFill: 0.8,
                                                  trial: model(1, calls: &calls))
        #expect(best?.side == 800 && calls == [800])
    }

    @Test("it gives up (nil) when even the floor is too big, and never goes below it")
    func floorGivesUp() async throws {
        var calls: [Int] = []
        let best = try await ImageEncoder.fitSide(start: 1000, floor: 200, ceiling: 1000, target: 100, minFill: 0.8,
                                                  trial: model(50, calls: &calls))
        #expect(best == nil)
        #expect(calls.min() == 200 && calls.count <= 14)
    }

    @Test("a wrong first guess that doesn't fit still ends up fitting")
    func recoversFromAMiss() async throws {
        var calls: [Int] = []
        let target: Int64 = 1_000_000
        let k = Double(target) * 30 / pow(2000, 1.7)
        let best = try await ImageEncoder.fitSide(start: 1900, floor: 100, ceiling: 2000, target: target, minFill: 0.8,
                                                  trial: model(k, calls: &calls))
        #expect((best?.bytes ?? .max) <= target)
    }
}

@Suite("Fit to size: planning")
struct FitPlanningTests {
    private let planner = EncodePlanner()
    private let url = URL(fileURLWithPath: "/tmp/io-fit/in.gif")

    private func fit(_ info: ImageInfo, mb: Double = 10, force: Bool = false) -> ImagePlan {
        var s = Settings(); s.encoderMode = .fitToSize; s.targetSizeMB = mb
        return planner.plan(info: info, inputURL: url, settings: s, forceEncode: force)
    }

    @Test("a file over the limit gets one fit step carrying the target, and must keep its result")
    func overTheLimit() {
        let plan = fit(ImageInfo(format: .gif, width: 1912, height: 1197, fileSize: 88_200_377))
        #expect(plan.steps == [.fitToSize(targetBytes: 10_000_000)])
        #expect(plan.fitTargetBytes == 10_000_000)
        #expect(!plan.isLossless)
    }

    @Test("every format is handled", arguments: [ImageFormat.jpeg, .png, .heic, .gif, .raw])
    func everyFormat(format: ImageFormat) {
        let plan = fit(ImageInfo(format: format, width: 4000, height: 3000, fileSize: 30_000_000))
        #expect(plan.steps == [.fitToSize(targetBytes: 10_000_000)])
    }

    @Test("a file already under the limit is left alone, and says why")
    func alreadyFits() {
        let plan = fit(ImageInfo(format: .jpeg, width: 4000, height: 3000, fileSize: 6_000_000))
        guard case .refused(.alreadyEfficient(let why)) = plan.outcome else { Issue.record("expected a refusal"); return }
        #expect(why.contains("10.0 MB") && why.contains("6.0 MB"))
    }

    @Test("Convert Anyway on a file that already fits just optimises it normally")
    func forceOnSmall() {
        let plan = fit(ImageInfo(format: .gif, width: 400, height: 300, fileSize: 6_000_000), force: true)
        #expect(plan.fitTargetBytes == nil)
        #expect(plan.steps == [.gifsicle(lossy: 10, maxSide: nil)])
    }

    @Test("a RAW is never 'already under the limit': it always becomes a new JPEG")
    func rawAlwaysFits() {
        let plan = fit(ImageInfo(format: .raw, width: 4000, height: 3000, fileSize: 5_000_000))
        #expect(plan.steps == [.fitToSize(targetBytes: 10_000_000)])
    }

    @Test("the target is in decimal megabytes, never below 0.1 MB, and old settings load with 10")
    func settings() throws {
        var s = Settings(); s.targetSizeMB = 8
        #expect(s.targetBytes == 8_000_000)
        s.targetSizeMB = 0
        #expect(s.targetBytes == 100_000)
        let old = #"{"encoderMode":"smallest"}"#
        #expect(try JSONDecoder().decode(Settings.self, from: Data(old.utf8)).targetSizeMB == 10)
        s.encoderMode = .fitToSize; s.targetSizeMB = 7.5
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite("Fit to size: real files", .serialized, .timeLimit(.minutes(5)))
final class FitRealFileTests {
    private let dir: URL
    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    private func size(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? -1 }

    /// Runs the real pipeline (queue, encoder, guards) on `src` with a target in bytes.
    private func run(_ src: URL, targetBytes: Int64) async throws -> Job {
        var s = Settings(); s.encoderMode = .fitToSize; s.targetSizeMB = Double(targetBytes) / 1_000_000
        let queue = JobQueue(maxConcurrent: 1, settings: s)
        let id = await queue.addJob(url: src, forceEncode: false)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !(await queue.isIdle) { try? await Task.sleep(for: .milliseconds(50)) }
        return try #require(await queue.job(id: id))
    }

    private func dims(_ url: URL) -> (Int, Int)? {
        guard let p = Fixtures.properties(url) as? [CFString: Any] else { return nil }
        guard let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    @Test("JPEG: quality alone is enough when the target is a moderate squeeze", .enabled(if: Requirements.jpegli))
    func jpegQualityOnly() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1600, height: 1200, seed: 7), to: dir.appendingPathComponent("a.jpg"), type: .jpeg, quality: 0.97)
        let target = size(src) / 2
        let job = try await run(src, targetBytes: max(100_000, target))
        #expect(job.state == .succeeded, "\(job.state) \(job.error)")
        let out = try #require(job.resultURL)
        #expect(size(out) <= max(100_000, target))
        #expect(dims(out)! == (1600, 1200), "should not have resized: \(dims(out)!)")
    }

    @Test("JPEG: a harsh target shrinks the picture, keeping its proportions", .enabled(if: Requirements.jpegli))
    func jpegResizes() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 4800, height: 3200, seed: 9), to: dir.appendingPathComponent("b.jpg"), type: .jpeg, quality: 0.97)
        let job = try await run(src, targetBytes: 100_000)
        #expect(job.state == .succeeded, "\(job.state) \(job.error)")
        let out = try #require(job.resultURL)
        #expect(size(out) <= 100_000)
        let (w, h) = try #require(dims(out))
        #expect(w < 4800 && abs(Double(w) / Double(h) - 1.5) < 0.02, "\(w)x\(h)")
    }

    @Test("a result only slightly smaller than the source is still kept (the usual 'not worth it' check doesn't apply)", .enabled(if: Requirements.jpegli))
    func closeToTheSourceIsKept() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1200, height: 900, seed: 3), to: dir.appendingPathComponent("c.jpg"), type: .jpeg, quality: 0.8)
        let target = size(src) - size(src) / 25            // 4% under: far above the 92% bar
        let job = try await run(src, targetBytes: max(100_000, target))
        #expect(job.state == .succeeded, "\(job.state) \(job.error)")
        #expect(size(try #require(job.resultURL)) <= max(100_000, target))
    }

    @Test("PNG ends up under the limit", .enabled(if: Requirements.png))
    func pngFits() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1200, height: 800, seed: 5), to: dir.appendingPathComponent("p.png"), type: .png)
        let job = try await run(src, targetBytes: 150_000)
        #expect(job.state == .succeeded, "\(job.state) \(job.error)")
        #expect(size(try #require(job.resultURL)) <= 150_000)
    }

    @Test("HEIC ends up under the limit")
    func heicFits() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 2000, height: 1500, seed: 11), to: dir.appendingPathComponent("h.heic"), type: .heic, quality: 0.95)
        let target = max(100_000, size(src) / 3)
        let job = try await run(src, targetBytes: target)
        #expect(job.state == .succeeded, "\(job.state) \(job.error)")
        #expect(size(try #require(job.resultURL)) <= target)
    }

    @Test("an image already under the limit is not touched")
    func smallIsRefused() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 300, height: 200), to: dir.appendingPathComponent("s.jpg"), type: .jpeg, quality: 0.9)
        let job = try await run(src, targetBytes: 10_000_000)
        #expect(job.state == .alreadyOptimized, "\(job.state)")
        #expect(job.resultURL == nil)
    }

    @Test("a GIF is shrunk under the limit with every frame, its delay and its loop count kept", .enabled(if: Requirements.gifsicle))
    func gifFits() async throws {
        let src = try Fixtures.movingSquareGIF(to: dir.appendingPathComponent("g.gif"), frames: 24, size: 480, delay: 0.07, loopCount: 3)
        // Plan by hand: the size to fit under is below the 0.1 MB floor a user can pick.
        let info = try ImageProbe.probe(url: src)
        let target = size(src) / 4
        var plan = EncodePlanner().plan(info: info, inputURL: src, settings: Settings(), forceEncode: true)
        plan.steps = [.fitToSize(targetBytes: target)]; plan.fitTargetBytes = target
        let out = dir.appendingPathComponent("g-out.gif")
        let report = try await ImageEncoder().encode(plan: plan, info: info, to: out)
        #expect(size(out) <= target, "\(size(out)) vs \(target)")
        let after = try ImageProbe.probe(url: out)
        #expect(after.frameCount == 24)
        #expect(after.width < 480)
        #expect(report.notes.joined().contains("Fitted"))
        func totals(_ url: URL) -> (loops: Int?, delay: Double) {
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, -1) }
            var delay = 0.0
            for i in 0..<CGImageSourceGetCount(s) {
                let d = (CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                delay += (d?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
            }
            let g = (CGImageSourceCopyProperties(s, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (g?[kCGImagePropertyGIFLoopCount] as? Int, (delay * 100).rounded() / 100)
        }
        #expect(totals(out).loops == 3)
        #expect(totals(out).delay == totals(src).delay, "total running time must not change")
    }
}
