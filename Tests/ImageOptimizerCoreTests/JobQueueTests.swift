// JobQueueTests.swift - The whole pipeline end to end: real files, real encoders, real queue.

import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ImageOptimizerCore

@Suite("JobQueue", .serialized, .timeLimit(.minutes(5)), .enabled(if: Requirements.jpegli && Requirements.png))
final class JobQueueTests {
    private let dir: URL
    init() throws { dir = try Fixtures.makeDirectory() }
    deinit { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Helpers

    private func photo(_ name: String, width: Int = 1024, height: Int = 768, quality: Double = 0.97, seed: UInt64 = 42) throws -> URL {
        try Fixtures.write(Fixtures.photoLike(width: width, height: height, seed: seed), to: dir.appendingPathComponent(name), type: .jpeg, quality: quality)
    }

    private func waitUntilIdle(_ queue: JobQueue, timeout: TimeInterval = 90) async -> [Job] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await queue.isIdle { return await queue.snapshot() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await queue.snapshot()
    }

    private func waitFor(_ queue: JobQueue, _ id: UUID, timeout: TimeInterval = 60, _ predicate: (Job) -> Bool) async -> Job? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = await queue.job(id: id), predicate(job) { return job }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await queue.job(id: id)
    }

    private func size(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? -1 }

    // MARK: - The happy path

    @Test("a fat JPEG is optimised: smaller output beside the source, original untouched")
    func jpegSucceeds() async throws {
        let src = try photo("a.jpg")
        let before = size(src)
        let queue = JobQueue(maxConcurrent: 2)
        let id = await queue.addJob(url: src)
        let jobs = await waitUntilIdle(queue)
        let job = try #require(jobs.first { $0.id == id })
        #expect(job.state == .succeeded, "\(job.state): \(job.error)")
        let out = try #require(job.resultURL)
        #expect(out.lastPathComponent == "a_optimized.jpg")
        #expect(size(out) < before)
        #expect(job.resultSize == size(out))
        #expect(size(src) == before, "the original must never be modified")
        #expect(!FileManager.default.fileExists(atPath: out.path + ".part"), "no .part left behind")
    }

    @Test("a screenshot-style PNG is optimised")
    func pngSucceeds() async throws {
        let src = try Fixtures.write(Fixtures.uiLike(), to: dir.appendingPathComponent("ui.png"), type: .png)
        let queue = JobQueue()
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.state == .succeeded, "\(job.state): \(job.error)")
        #expect(try #require(job.resultSize) < size(src))
    }

    @Test("a HEIC is optimised")
    func heicSucceeds() async throws {
        let src = try Fixtures.write(Fixtures.photoLike(width: 1600, height: 1200), to: dir.appendingPathComponent("h.heic"), type: .heic, quality: 0.98)
        let queue = JobQueue()
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.state == .succeeded, "\(job.state): \(job.error)")
    }

    // MARK: - Scheduling (each of these was a real VideoOptimizer bug)

    @Test("a job added after the first has finished still runs")
    func secondAfterFirst() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        let a = await queue.addJob(url: try photo("a.jpg"))
        _ = await waitUntilIdle(queue)
        let b = await queue.addJob(url: try photo("b.jpg", seed: 7))
        let jobs = await waitUntilIdle(queue)
        #expect(jobs.first { $0.id == a }?.state == .succeeded)
        #expect(jobs.first { $0.id == b }?.state == .succeeded)
    }

    @Test("a job added while another is running is queued, then runs")
    func queuedWhileBusy() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        let a = await queue.addJob(url: try photo("a.jpg", width: 3000, height: 2000))
        let b = await queue.addJob(url: try photo("b.jpg", seed: 7))
        #expect(await queue.job(id: b)?.state == .queued, "with one slot busy, the second must wait")
        let jobs = await waitUntilIdle(queue)
        #expect(jobs.first { $0.id == a }?.state == .succeeded)
        #expect(jobs.first { $0.id == b }?.state == .succeeded, "the queued job must run once the slot frees")
    }

    @Test("concurrency is honoured and never exceeded")
    func concurrencyLimit() async throws {
        // Generate every file FIRST: creating them inside the add loop let early jobs finish
        // before later ones were queued, which made overlap impossible to observe.
        let files = try (0..<9).map { try photo("c\($0).jpg", width: 2000, height: 1500, seed: UInt64($0 + 1)) }
        let queue = JobQueue(maxConcurrent: 3)
        for file in files { await queue.addJob(url: file) }
        var peak = 0
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let running = await queue.snapshot().filter { [.probing, .planning, .encoding].contains($0.state) }.count
            peak = max(peak, running)
            if await queue.isIdle { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let jobs = await queue.snapshot()
        #expect(jobs.allSatisfy { $0.state == .succeeded }, "\(jobs.map(\.state))")
        #expect(peak <= 3, "peak concurrency \(peak) exceeded the limit of 3")
        #expect(peak >= 2, "9 jobs with 3 slots should actually overlap (peak \(peak))")
    }

    @Test("a failure in one job doesn't affect the others")
    func failureIsolated() async throws {
        let bad = dir.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: bad)
        let queue = JobQueue(maxConcurrent: 2)
        let good = await queue.addJob(url: try photo("good.jpg"))
        let broken = await queue.addJob(url: bad)
        let jobs = await waitUntilIdle(queue)
        #expect(jobs.first { $0.id == good }?.state == .succeeded)
        let b = try #require(jobs.first { $0.id == broken })
        #expect(b.state == .failed && !b.error.isEmpty, "a failure must say why")
    }

    // MARK: - Cancellation

    @Test("cancelling a queued job stops it ever running")
    func cancelQueued() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        await queue.addJob(url: try photo("a.jpg", width: 3000, height: 2000))
        let b = await queue.addJob(url: try photo("b.jpg", seed: 7))
        await queue.cancel(id: b)
        let jobs = await waitUntilIdle(queue)
        #expect(jobs.first { $0.id == b }?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b_optimized.jpg").path))
    }

    /// The headline VideoOptimizer failure: Stop did nothing, because the queue had no handle on
    /// the running work.
    @Test("cancelling a RUNNING job actually stops it and leaves nothing behind")
    func cancelRunning() async throws {
        // 6000x4000 noise is slow enough to still be encoding when the cancel lands.
        let src = try photo("big.jpg", width: 6000, height: 4000)
        let queue = JobQueue(maxConcurrent: 1)
        let id = await queue.addJob(url: src)
        _ = await waitFor(queue, id) { $0.state == .encoding }
        await queue.cancel(id: id)
        let job = try #require(await waitFor(queue, id, timeout: 30) { !$0.isActive })
        #expect(job.state == .cancelled, "got \(job.state): \(job.error)")
        let out = dir.appendingPathComponent("big_optimized.jpg")
        #expect(!FileManager.default.fileExists(atPath: out.path), "a cancelled job must not produce output")
        #expect(!FileManager.default.fileExists(atPath: out.path + ".part"), "and must not leave a .part file")
        #expect(await queue.isIdle)
    }

    @Test("after cancelling a file, the same file can be dropped again and succeeds")
    func redropAfterCancel() async throws {
        let src = try photo("big.jpg", width: 5000, height: 3500)
        let queue = JobQueue(maxConcurrent: 1)
        let first = await queue.addJob(url: src)
        _ = await waitFor(queue, first) { $0.state == .encoding }
        await queue.cancel(id: first)
        _ = await waitFor(queue, first, timeout: 30) { !$0.isActive }
        let second = await queue.addJob(url: src)
        let job = try #require(await waitFor(queue, second, timeout: 90) { !$0.isActive })
        #expect(job.state == .succeeded, "\(job.state): \(job.error)")
    }

    // MARK: - Refusals

    @Test("an animated PNG is still unsupported, with the reason shown")
    func apngUnsupported() async throws {
        // Only GIF animation is handled; any other animated format would be flattened to one frame.
        var info = ImageInfo(format: .png, width: 64, height: 64, fileSize: 40_000)
        info.frameCount = 4
        let p = EncodePlanner().plan(info: info, inputURL: dir.appendingPathComponent("a.png"), settings: Settings())
        guard case .refused(.unsupported(let why)) = p.outcome else { Issue.record("expected unsupported"); return }
        #expect(why.contains("Animated"))
    }

    @Test("an already-squeezed JPEG is refused, and forcing it produces real output")
    func refuseThenForce() async throws {
        // 640x480 at q0.12 is ~0.3 bits/pixel: far below the balanced floor.
        let src = try photo("thin.jpg", width: 640, height: 480, quality: 0.12)
        let queue = JobQueue()
        let first = await queue.addJob(url: src)
        let refused = try #require(await waitUntilIdle(queue).first { $0.id == first })
        #expect(refused.state == .alreadyOptimized, "\(refused.state)")
        #expect(refused.error.contains("bits/pixel"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("thin_optimized.jpg").path))

        let forced = await queue.addJob(url: src, forceEncode: true)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == forced })
        #expect(job.state == .succeeded, "forcing must produce real output, got \(job.state): \(job.error)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("thin_optimized.jpg").path))
    }

    @Test("a result no smaller than the source is discarded, not written")
    func postFlightDiscard() async throws {
        // Source: a low-quality noisy JPEG with enough bits/pixel to pass the pre-flight check,
        // but whose pixels a visually-lossless re-encode can only make LARGER.
        var rng = Fixtures.SeededRandom(state: 5)
        let w = 800, h = 600
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<px.count where i % 4 != 3 { px[i] = rng.next() }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let src = try Fixtures.write(ctx.makeImage()!, to: dir.appendingPathComponent("noise.jpg"), type: .jpeg, quality: 0.4)
        var s = Settings(); s.encoderMode = .highQuality
        let queue = JobQueue(settings: s)
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.state == .discardedAsBlob, "got \(job.state): \(job.error)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("noise_optimized.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("noise_optimized.jpg.part").path))
    }

    // MARK: - Output handling (VideoOptimizer's silent-overwrite bug)

    @Test("optimising the same file twice overwrites cleanly, leaving no orphan .part")
    func overwriteWorks() async throws {
        let src = try photo("a.jpg")
        let out = dir.appendingPathComponent("a_optimized.jpg")
        try Data("STALE".utf8).write(to: out)
        let queue = JobQueue()
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.state == .succeeded, "\(job.state): \(job.error)")
        #expect(size(out) > 1000, "the stale placeholder must have been replaced by a real image")
        #expect(!FileManager.default.fileExists(atPath: out.path + ".part"))
        _ = try ImageProbe.probe(url: out)
    }

    @Test("the numberIt policy never overwrites an existing result")
    func numberItKeepsExisting() async throws {
        let src = try photo("a.jpg")
        var s = Settings(); s.conflictPolicy = .numberIt
        let queue = JobQueue(maxConcurrent: 1, settings: s)
        await queue.addJob(url: src)
        _ = await waitUntilIdle(queue)
        await queue.addJob(url: src)
        _ = await waitUntilIdle(queue)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a_optimized.jpg").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a_optimized 1.jpg").path))
    }

    @Test("the output keeps the source's modification date when asked")
    func preservesDates() async throws {
        let src = try photo("a.jpg")
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)
        let queue = JobQueue()
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        let out = try #require(job.resultURL)
        let modified = try #require(FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince(old)) < 2)
    }

    @Test("an output folder choice is honoured")
    func chosenFolder() async throws {
        let src = try photo("a.jpg")
        let folder = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var s = Settings(); s.outputLocation = .chooseFolder; s.chosenFolderPath = folder.path
        let queue = JobQueue(settings: s)
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.resultURL?.deletingLastPathComponent().path == folder.path)
    }

    @Test("delete-original sends the source to the Trash, only after a successful conversion")
    func deleteSourceTrashes() async throws {
        let src = try photo("trashme-\(UUID().uuidString.prefix(6)).jpg")
        var s = Settings(); s.deleteSource = true
        let queue = JobQueue(settings: s)
        let id = await queue.addJob(url: src)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.state == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: src.path), "the original should be gone")
        #expect(FileManager.default.fileExists(atPath: try #require(job.resultURL).path), "the result must exist")
        // Tidy: it should be recoverable from the Trash (that's the safety net), then we remove it.
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(src.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: trash.path), "the original must be in the Trash, not deleted for good")
        try? FileManager.default.removeItem(at: trash)
    }

    @Test("delete-original leaves the source alone when the conversion was refused")
    func deleteSourceKeepsOnRefusal() async throws {
        let thin = try photo("thin.jpg", width: 640, height: 480, quality: 0.12)
        var s = Settings(); s.deleteSource = true
        let queue = JobQueue(settings: s)
        let id = await queue.addJob(url: thin)
        let job = try #require(await waitUntilIdle(queue).first { $0.id == id })
        #expect(job.state == .alreadyOptimized)
        #expect(FileManager.default.fileExists(atPath: thin.path), "never delete an original that wasn't replaced")
    }
}
