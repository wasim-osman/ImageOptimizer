import AppKit
import ImageOptimizerCore

/// The whole main window: a drop target and nothing else. Dropping starts work immediately.
@MainActor
final class MainViewController: NSViewController, NSMenuItemValidation {

    private let dropZone = DropZoneView()
    private var queue: JobQueue
    private var queueConcurrency: Int
    private var pollTimer: Timer?
    private var lastOutputURL: URL?
    private var hasAnnouncedDrain = true
    /// Mirrors the queue so menu validation stays synchronous; refreshed on every poll.
    private var hasActiveJobs = false
    /// Jobs already folded into the lifetime total, so each counts exactly once however many times
    /// the poll timer sees it sitting finished.
    private var recordedJobIDs: Set<UUID> = []

    init() {
        let settings = SettingsStore.shared.settings
        queueConcurrency = settings.concurrency
        queue = JobQueue(maxConcurrent: settings.concurrency, settings: settings)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        dropZone.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
        dropZone.autoresizingMask = [.width, .height]
        dropZone.onDrop = { [weak self] urls in self?.enqueue(urls) }
        dropZone.onClick = { [weak self] in self?.revealLastOutput() }
        dropZone.onDoubleClick = { NSApp.sendAction(#selector(AppDelegate.openFilesDialog(_:)), to: NSApp.delegate, from: nil) }
        dropZone.onSettingsButtonTapped = { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: NSApp.delegate, from: nil) }
        dropZone.onStopButtonTapped = { [weak self] in self?.stopConverting(nil) }
        view = dropZone
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: SettingsStore.didChange, object: nil)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer?.invalidate()
        pollTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Input

    /// Entry point for files opened outside a drag: the Dock, Finder's Open With, a double click
    /// with this app as the default handler, or File ▸ Open…. A direct call from AppDelegate, not a
    /// notification: the notification used to be posted before anything was listening at launch.
    func enqueueExternally(_ urls: [URL]) { enqueue(DropZoneView.expand(urls)) }

    private func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        hasAnnouncedDrain = false
        Task { @MainActor in
            await adoptPendingConcurrencyIfIdle()
            let all = await queue.snapshot()
            // One drop can arrive through BOTH the drag handler and application(_:openFiles:), so
            // collapse duplicates — but only against jobs still IN FLIGHT. A cancelled, failed or
            // finished file must be droppable again.
            var seen = Set(all.filter(\.isActive).map { $0.inputURL.standardizedFileURL })
            for url in urls {
                let key = url.standardizedFileURL
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                if let refused = ForceConvert.shouldPromptToForce(url: url, among: all) {
                    guard confirmForceConvert(fileName: url.lastPathComponent, reason: refused.error) else { continue }
                    await queue.addJob(url: url, forceEncode: true)
                } else {
                    await queue.addJob(url: url)
                }
            }
            refresh()
        }
    }

    /// "Convert Anyway?" after a file was already refused once by the size guard.
    private func confirmForceConvert(fileName: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Optimise \"\(fileName)\" anyway?"
        alert.informativeText = "\(reason)\n\nIt will still be processed, but it may not get smaller, "
            + "and re-encoding an image loses a little quality each time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Optimise Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `JobQueue` fixes its concurrency at init, so a changed setting takes effect on the next drop
    /// that arrives while nothing is running.
    private func adoptPendingConcurrencyIfIdle() async {
        let desired = SettingsStore.shared.settings.concurrency
        guard desired != queueConcurrency, await queue.isIdle else { return }
        queueConcurrency = desired
        queue = JobQueue(maxConcurrent: desired, settings: SettingsStore.shared.settings)
    }

    @objc private func settingsChanged() {
        let settings = SettingsStore.shared.settings
        Task { await queue.setSettings(settings) }
    }

    // MARK: - Cancelling

    /// File ▸ Stop (⌘.). Reaches the running encoder processes through the queue.
    @objc func stopConverting(_ sender: Any?) {
        Task { @MainActor in
            await queue.cancelAll()
            refresh()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(stopConverting(_:)) else { return true }
        return hasActiveJobs
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, hasActiveJobs { stopConverting(nil); return }   // Esc
        super.keyDown(with: event)
    }

    var hasJobsWorthWarningAboutOnQuit: Bool { hasActiveJobs }

    /// Cancels everything and waits (bounded) for the encoders to actually exit, so quitting never
    /// leaves an orphaned process running with nothing able to see or stop it.
    func stopAllJobsForQuit() async {
        await queue.cancelAll()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !(await queue.isIdle) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func revealLastOutput() {
        guard let url = lastOutputURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Status

    private func refresh() {
        guard view.window != nil else { return }
        Task { @MainActor in render(await queue.snapshot()) }
    }

    private func render(_ jobs: [Job]) {
        recordNewlySucceeded(jobs)
        let active = jobs.filter(\.isActive)
        hasActiveJobs = !active.isEmpty
        dropZone.setStopButtonVisible(hasActiveJobs)
        lastOutputURL = jobs.last(where: { $0.state == .succeeded })?.resultURL ?? lastOutputURL

        guard !jobs.isEmpty else {
            dropZone.show(.init(headline: "Drop images here", detail: "", progress: nil, lifetimeCaption: lifetimeCaption()))
            return
        }

        if !active.isEmpty {
            let finished = jobs.count - active.count
            let headline = jobs.count == 1 ? "Optimising…" : "Optimising · \(finished) of \(jobs.count) done"

            var parts: [String] = []
            let running = active.filter { [.probing, .planning, .encoding].contains($0.state) }
            if let first = running.first {
                parts.append(running.count > 1 ? "\(first.inputURL.lastPathComponent) (+\(running.count - 1) more)"
                                               : first.inputURL.lastPathComponent)
            }
            // Name what is waiting, so a drop made while busy is visibly queued, not silently ignored.
            let queued = active.filter { $0.state == .queued }
            if let next = queued.first {
                let more = queued.count - 1
                parts.append(more > 0 ? "next: \(next.inputURL.lastPathComponent) (+\(more))" : "next: \(next.inputURL.lastPathComponent)")
            }
            let overall = jobs.reduce(0.0) { $0 + $1.progress } / Double(jobs.count)
            dropZone.show(.init(headline: headline, detail: parts.joined(separator: " · "), progress: overall))
            return
        }

        announceDrainIfNeeded()
        dropZone.show(.init(headline: IdleSummary.headline(for: jobs), detail: IdleSummary.detail(for: jobs),
                            progress: nil, lifetimeCaption: lifetimeCaption()))
    }

    /// Only genuine `.succeeded` conversions count: a refusal never touched a real output file.
    private func recordNewlySucceeded(_ jobs: [Job]) {
        for job in jobs where job.state == .succeeded && !recordedJobIDs.contains(job.id) {
            recordedJobIDs.insert(job.id)
            guard let resultSize = job.resultSize else { continue }
            LifetimeStatsStore.shared.record(inputBytes: job.inputSize, outputBytes: resultSize)
        }
    }

    private func lifetimeCaption() -> String {
        let stats = LifetimeStatsStore.shared.stats
        guard stats.filesConverted > 0 else { return "" }
        let files = stats.filesConverted == 1 ? "1 image" : "\(stats.filesConverted) images"
        let f = ByteCountFormatter(); f.countStyle = .file
        return "Lifetime: \(f.string(fromByteCount: stats.totalBytesSaved)) saved across \(files)"
    }

    private func announceDrainIfNeeded() {
        guard !hasAnnouncedDrain else { return }
        hasAnnouncedDrain = true
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}
