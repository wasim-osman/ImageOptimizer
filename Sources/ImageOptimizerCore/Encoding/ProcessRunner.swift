// ProcessRunner.swift - Runs one external tool to completion, cancellably.
//
// Built from the lessons VideoOptimizer paid for: completion comes from terminationHandler
// (never a blocking waitUntilExit), pipe readers clear themselves at EOF (they otherwise spin a
// thread), and a cancel that lands before launch is honoured rather than dropped.

import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stderr: String
    var wasCancelled: Bool
}

enum ProcessRunner {
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Mutable state shared between the launching closure, the termination handler and the
    /// cancellation handler, which run on different threads.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var stderrData = Data()

        func attach(_ p: Process) { lock.lock(); process = p; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func appendStderr(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            stderrData.append(d)
            if stderrData.count > 16_384 { stderrData = stderrData.suffix(16_384) }   // keep the tail
        }
        var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stderrData, as: UTF8.self) }

        func cancel() {
            lock.lock()
            cancelled = true
            let p = process
            lock.unlock()
            // terminate() on a process that hasn't launched raises an exception, so check first.
            if let p, p.isRunning { p.terminate() }
        }
    }

    /// `feedStdin` runs on a background queue and may write as much as it likes; stdin is closed
    /// when it returns, which is how the tool learns the input is complete.
    static func run(
        _ executable: URL,
        arguments: [String],
        feedStdin: (@Sendable (FileHandle) throws -> Void)? = nil
    ) async -> ProcessResult {
        _ = ignoreSIGPIPE
        let state = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.qualityOfService = .utility   // a batch must not starve the UI

                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = FileHandle.nullDevice
                let inPipe: Pipe? = feedStdin == nil ? nil : Pipe()
                if let inPipe { process.standardInput = inPipe } else { process.standardInput = FileHandle.nullDevice }

                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; return }   // EOF: stop being called
                    state.appendStderr(data)
                }
                process.terminationHandler = { finished in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? errPipe.fileHandleForReading.readToEnd() { state.appendStderr(rest) }
                    continuation.resume(returning: ProcessResult(
                        exitCode: finished.terminationStatus, stderr: state.stderrText, wasCancelled: state.isCancelled
                    ))
                }
                state.attach(process)
                if state.isCancelled {
                    continuation.resume(returning: ProcessResult(exitCode: -1, stderr: "", wasCancelled: true))
                    return
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: ProcessResult(
                        exitCode: -1, stderr: "couldn't launch \(executable.lastPathComponent): \(error.localizedDescription)",
                        wasCancelled: false
                    ))
                    return
                }
                // A cancel that arrived while the process was starting would otherwise be lost.
                if state.isCancelled { process.terminate() }
                if let feedStdin, let inPipe {
                    DispatchQueue.global(qos: .utility).async {
                        do { try feedStdin(inPipe.fileHandleForWriting) } catch { /* tool exited early: its exit code says why */ }
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
