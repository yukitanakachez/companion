import CompanionCore
import Foundation

/// In-memory conversation state with the 10-minute resume window (spec §5.2, §5.7).
/// A turn is stored only once its answer exists, so user and assistant messages always alternate.
public struct ConversationStore: Sendable {
    public struct Turn: Sendable, Equatable {
        public var question: String
        public var userMessage: LLMMessage
        public var answer: String

        public init(question: String, userMessage: LLMMessage, answer: String) {
            self.question = question
            self.userMessage = userMessage
            self.answer = answer
        }
    }

    public static let resumeWindow: TimeInterval = 600

    public private(set) var turns: [Turn] = []
    public private(set) var lastInteraction: Date?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public var messages: [LLMMessage] {
        turns.flatMap { [$0.userMessage, LLMMessage(role: .assistant, content: [.text($0.answer)])] }
    }

    /// True when the previous thread resumes; false also clears the turns. Does not touch.
    public mutating func beginSummon() -> Bool {
        if !turns.isEmpty, let lastInteraction,
           now().timeIntervalSince(lastInteraction) <= Self.resumeWindow {
            return true
        }
        turns = []
        return false
    }

    public mutating func appendTurn(question: String, userMessage: LLMMessage, answer: String) {
        turns.append(Turn(question: question, userMessage: userMessage, answer: answer))
        touch()
    }

    public mutating func touch() {
        lastInteraction = now()
    }

    public mutating func reset() {
        turns = []
        lastInteraction = nil
    }
}
