// RememberedAnswers.swift - "Apply to all remaining images": one answer to a question, reused for the rest of a drop.

import Foundation

/// The yes/no answers the user chose to apply to every remaining image of the same question in the current drop.
/// HDR ("optimise without the HDR layer?") and the size guard ("optimise anyway?") are separate questions, so
/// answering one for everything never answers the other.
public struct RememberedAnswers: Sendable, Equatable {
    public enum Question: Hashable, Sendable { case hdr, force }

    private var answers: [Question: Bool] = [:]

    public init() {}

    /// The remembered answer, or nil when the user should be asked.
    public func answer(for question: Question) -> Bool? { answers[question] }

    /// Records `answer` only when the user ticked "apply to all", so a plain click answers just that one image.
    public mutating func remember(_ answer: Bool, for question: Question, applyToAll: Bool) {
        if applyToAll { answers[question] = answer }
    }

    /// The drop is finished: the next drop asks again.
    public mutating func reset() { answers.removeAll() }
}
