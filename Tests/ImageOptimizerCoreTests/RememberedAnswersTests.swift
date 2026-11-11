// RememberedAnswersTests.swift - "Apply to all remaining images" for the HDR and "optimise anyway" questions.

import Testing
@testable import ImageOptimizerCore

@Suite("Remembered answers")
struct RememberedAnswersTests {
    @Test("nothing is remembered until the user ticks apply-to-all")
    func plainClickAnswersOnlyThatImage() {
        var r = RememberedAnswers()
        r.remember(true, for: .hdr, applyToAll: false)
        r.remember(false, for: .force, applyToAll: false)
        #expect(r.answer(for: .hdr) == nil && r.answer(for: .force) == nil)
    }

    @Test("a ticked yes and a ticked cancel are both remembered")
    func rememberedEitherWay() {
        var r = RememberedAnswers()
        r.remember(true, for: .hdr, applyToAll: true)
        r.remember(false, for: .force, applyToAll: true)
        #expect(r.answer(for: .hdr) == true)
        #expect(r.answer(for: .force) == false)
    }

    @Test("answering one question for everything never answers the other")
    func questionsAreIndependent() {
        var r = RememberedAnswers()
        r.remember(true, for: .hdr, applyToAll: true)
        #expect(r.answer(for: .force) == nil)
    }

    @Test("the next drop asks again")
    func resetForgets() {
        var r = RememberedAnswers()
        r.remember(true, for: .hdr, applyToAll: true)
        r.reset()
        #expect(r == RememberedAnswers() && r.answer(for: .hdr) == nil)
    }
}

@Suite("Remembered answers: portrait")
struct RememberedDepthAnswerTests {
    @Test("the Portrait answer is independent of the HDR and optimise-anyway answers")
    func independent() {
        var r = RememberedAnswers()
        r.remember(true, for: .depth, applyToAll: true)
        #expect(r.answer(for: .depth) == true && r.answer(for: .hdr) == nil && r.answer(for: .force) == nil)
    }
}
