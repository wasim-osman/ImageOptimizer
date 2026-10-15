// JobQueue.swift - The single actor that owns the queue.
//
// Orchestration lessons carried over from VideoOptimizer, each of which was a real bug there:
//  * Cancel must reach the running work (the queue keeps each job's Task and cancels it).
//  * A cancelled/failed/succeeded file must be droppable again; only in-flight jobs dedupe.
//  * Completion comes from awaiting, never from blocking a cooperative thread.

import Foundation

public actor JobQueue {
    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var active = 0
    private let maxConcurrent: Int
    private var settings: Settings
    private var sleepActivity: NSObjectProtocol?
    private let encoder = ImageEncoder()

    public init(maxConcurrent: Int = 4, settings: Settings = Settings()) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.settings = settings
    }

    // MARK: - Public API

    public func setSettings(_ new: Settings) { settings = new }
    public func snapshot() -> [Job] { order.compactMap { jobs[$0] } }
    public func job(id: UUID) -> Job? { jobs[id] }

    @discardableResult
    public func addJob(url: URL, forceEncode: Bool = false) -> UUID {
        let job = Job(inputURL: url, forceEncode: forceEncode)
        jobs[job.id] = job
        order.append(job.id)
        drain()
        return job.id
    }

    /// Cancels a queued job immediately, or a running one by cancelling its task, which kills the
    /// encoder process. The state flips to `.cancelled` only once the work has actually stopped.
    public func cancel(id: UUID) {
        guard let job = jobs[id] else { return }
        if job.state == .queued {
            update(id) { $0.state = .cancelled }
        } else if let task = tasks[id] {
            task.cancel()
        }
    }

    public func cancelAll() { for id in order { cancel(id: id) } }

    /// True once nothing is queued or running.
    public var isIdle: Bool { !jobs.values.contains { $0.isActive } }

    // MARK: - Scheduling

    private func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        mutate(&job)
        jobs[id] = job
    }

    private func drain() {
        while active < maxConcurrent, let next = order.first(where: { jobs[$0]?.state == .queued }) {
            active += 1
            beginActivityIfNeeded()
            update(next) { $0.state = .probing }          // claim it so drain can't pick it twice
            tasks[next] = Task { await self.process(next) }
        }
    }

    private func finish(_ id: UUID) {
        active -= 1
        tasks[id] = nil
        if active == 0, !jobs.values.contains(where: { $0.state == .queued }) { endActivity() }
        drain()
    }

    /// Keeps the Mac awake for the duration of a batch, and releases it afterwards. (VideoOptimizer
    /// took this assertion and never released it, so the Mac could never idle-sleep again.)
    private func beginActivityIfNeeded() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "ImageOptimizer optimising images")
    }

    private func endActivity() {
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity) }
        sleepActivity = nil
    }

    // MARK: - Pipeline

    private func process(_ id: UUID) async {
        guard let job = jobs[id] else { finish(id); return }
        let settings = self.settings

        // Probe
        let info: ImageInfo
        do {
            info = try ImageProbe.probe(url: job.inputURL)
        } catch let error as ProbeError {
            if case .unsupportedFormat = error {
                update(id) { $0.state = .unsupported; $0.error = error.localizedDescription; $0.progress = 1 }
            } else {
                update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
            finish(id); return
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            finish(id); return
        }

        // Plan
        update(id) { $0.state = .planning }
        let plan = EncodePlanner().plan(info: info, inputURL: job.inputURL, settings: settings, forceEncode: job.forceEncode)
        switch plan.outcome {
        case .refused(.alreadyEfficient(let reason)):
            update(id) { $0.state = .alreadyOptimized; $0.error = reason; $0.progress = 1 }
            finish(id); return
        case .refused(.unsupported(let reason)):
            update(id) { $0.state = .unsupported; $0.error = reason; $0.progress = 1 }
            finish(id); return
        case .refused(.hdrLayer(let reason)):
            update(id) { $0.state = .hdrLayer; $0.error = reason; $0.progress = 1 }
            finish(id); return
        case .refused(.outputExists(let reason)):
            update(id) { $0.state = .skipped; $0.error = reason; $0.progress = 1 }
            finish(id); return
        case .planned:
            break
        }

        // A tool missing from the install is a clear failure, not a mysterious one.
        if let missing = ToolLocator.missing(for: info.format).first {
            update(id) { $0.state = .failed; $0.error = EncodeError.toolMissing(missing.rawValue).localizedDescription }
            finish(id); return
        }

        // Encode
        update(id) { $0.state = .encoding }
        let partURL = plan.outputURL.appendingPathExtension("part")
        do {
            let report = try await encoder.encode(plan: plan, info: info, to: partURL) { [weak self] fraction in
                Task { await self?.update(id) { $0.progress = fraction } }
            }
            try Task.checkCancellation(or: EncodeError.cancelled)
            let outcome = try OutputFinalizer.finalize(
                partURL: partURL, outputURL: plan.outputURL, inputURL: job.inputURL, inputSize: job.inputSize,
                lossless: plan.isLossless || report.producedLossless, bypassGuard: job.forceEncode, preserveDates: settings.preserveDates
            )
            switch outcome {
            case .discarded(let message):
                update(id) { $0.state = .discardedAsBlob; $0.error = message; $0.progress = 1 }
            case .promoted(let size):
                update(id) {
                    $0.state = .succeeded; $0.resultURL = plan.outputURL; $0.resultSize = size; $0.progress = 1
                    $0.error = report.notes.joined(separator: " ")
                }
                // Never a RAW: it is the negative, and the JPEG made from it is lossy and cannot be developed again.
                if settings.deleteSource, info.format != .raw { trash(job.inputURL) }
            }
        } catch EncodeError.cancelled {
            try? FileManager.default.removeItem(at: partURL)
            update(id) { $0.state = .cancelled }
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
        finish(id)
    }

    /// Recoverable, unlike removeItem: a mistaken "delete originals" costs a trip to the Trash.
    /// If the Trash can't take it, the original is left alone rather than deleted for good.
    private func trash(_ url: URL) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
}
