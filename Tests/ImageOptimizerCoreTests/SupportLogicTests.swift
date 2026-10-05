// SupportLogicTests.swift - Lifetime stats, "Convert Anyway" and the idle summary: the logic
// the app layer leans on, kept here because the app has no test target.

import Foundation
import Testing
@testable import ImageOptimizerCore

private func job(_ name: String = "a.jpg", state: JobState, error: String = "", input: Int64 = 0, result: Int64? = nil) -> Job {
    var j = Job(inputURL: URL(fileURLWithPath: "/tmp/\(name)"))
    j.state = state; j.error = error; j.inputSize = input; j.resultSize = result
    return j
}

@Suite("LifetimeStats")
struct LifetimeStatsTests {
    @Test("starts at zero")
    func zero() {
        let s = LifetimeStats()
        #expect(s.totalBytesSaved == 0 && s.filesConverted == 0)
    }

    @Test("accumulates across conversions rather than overwriting")
    func accumulates() {
        var s = LifetimeStats()
        s.record(inputBytes: 1_000_000, outputBytes: 400_000)
        s.record(inputBytes: 2_000_000, outputBytes: 900_000)
        #expect(s.filesConverted == 2)
        #expect(s.totalBytesSaved == 1_700_000)
    }

    @Test("never reports negative savings")
    func clamped() {
        var s = LifetimeStats()
        s.record(inputBytes: 100, outputBytes: 500)
        #expect(s.totalBytesSaved == 0)
    }

    @Test("round-trips through JSON, as it will through UserDefaults")
    func codable() throws {
        var s = LifetimeStats()
        s.record(inputBytes: 12_345_678_901, outputBytes: 2_345_678_901)
        let back = try JSONDecoder().decode(LifetimeStats.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite("ForceConvert")
struct ForceConvertTests {
    private let url = URL(fileURLWithPath: "/tmp/a.jpg")

    @Test("a size-guard refusal of this exact file prompts",
          arguments: [JobState.alreadyOptimized, .discardedAsBlob])
    func refusalPrompts(state: JobState) {
        #expect(ForceConvert.shouldPromptToForce(url: url, among: [job(state: state, error: "why")])?.error == "why")
    }

    /// Forcing an animated or HDR image would not make it safe, so it must never be offered.
    @Test("a skipped file never prompts: forcing it would just be skipped again")
    func skippedNeverPrompts() {
        #expect(ForceConvert.shouldPromptToForce(url: url, among: [job(state: .skipped, error: "exists")]) == nil)
    }

    @Test("an unsupported refusal never prompts")
    func unsupportedNeverPrompts() {
        #expect(ForceConvert.shouldPromptToForce(url: url, among: [job(state: .unsupported, error: "animated")]) == nil)
    }

    @Test("every other state does not prompt",
          arguments: [JobState.queued, .probing, .planning, .encoding, .succeeded, .failed, .cancelled])
    func otherStates(state: JobState) {
        #expect(ForceConvert.shouldPromptToForce(url: url, among: [job(state: state)]) == nil)
    }

    @Test("a different file never prompts")
    func differentFile() {
        #expect(ForceConvert.shouldPromptToForce(url: url, among: [job("b.jpg", state: .alreadyOptimized)]) == nil)
    }

    @Test("a later success clears the prompt, rather than reaching back to an older refusal")
    func laterSuccess() {
        let jobs = [job(state: .alreadyOptimized, error: "old"), job(state: .succeeded)]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs) == nil)
    }

    @Test("the most recent refusal's reason is the one shown")
    func mostRecent() {
        let jobs = [job(state: .alreadyOptimized, error: "first"), job(state: .discardedAsBlob, error: "second")]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs)?.error == "second")
    }
}

@Suite("IdleSummary")
struct IdleSummaryTests {
    @Test("no jobs shows the drop prompt")
    func empty() {
        #expect(IdleSummary.headline(for: []) == "Drop images here")
        #expect(IdleSummary.detail(for: []) == "")
    }

    @Test("every refusal's reason reaches the screen, never a blank line",
          arguments: [JobState.alreadyOptimized, .discardedAsBlob, .unsupported, .skipped, .failed])
    func reasonsShown(state: JobState) {
        #expect(IdleSummary.detail(for: [job(state: state, error: "the reason")]) == "the reason")
    }

    @Test("a succeeded batch's before/after beats any refusal")
    func succeededWins() {
        let d = IdleSummary.detail(for: [job(state: .succeeded, input: 1000, result: 400), job(state: .unsupported, error: "nope")])
        #expect(d.contains("→") && !d.contains("nope"))
    }

    @Test("a forced conversion that grew the file reads as growth, never a double negative")
    func growth() {
        let d = IdleSummary.detail(for: [job(state: .succeeded, input: 1000, result: 1250)])
        #expect(d.contains("+25% larger") && !d.contains("−-"))
    }

    @Test("every outcome is counted in the headline")
    func headline() {
        let h = IdleSummary.headline(for: [
            job(state: .succeeded, input: 10, result: 5), job(state: .alreadyOptimized), job(state: .discardedAsBlob),
            job(state: .unsupported), job(state: .skipped), job(state: .cancelled), job(state: .failed),
        ])
        for part in ["1 optimised", "2 already optimised", "1 unsupported", "1 skipped", "1 stopped", "1 failed"] {
            #expect(h.contains(part), "missing '\(part)' in '\(h)'")
        }
    }
}
