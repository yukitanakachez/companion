import CompanionCore
@testable import CompanionSession
import Testing

private let q1 = LLMMessage(role: .user, content: [.text("q1 + context")])

private func storeWithTurn(_ clock: TestClock) -> ConversationStore {
    var store = ConversationStore(now: clock.read)
    store.appendTurn(question: "q1", userMessage: q1, answer: "a1")
    return store
}

@Test func resumesAt599Seconds() {
    let clock = TestClock()
    var store = ConversationStore(now: clock.read)
    #expect(store.beginSummon() == false)
    store.appendTurn(question: "q1", userMessage: q1, answer: "a1")
    clock.advance(599)
    #expect(store.beginSummon() == true)
    #expect(store.messages == [q1, LLMMessage(role: .assistant, content: [.text("a1")])])
}

@Test func resumesAtExactly600Seconds() {
    let clock = TestClock()
    var store = storeWithTurn(clock)
    clock.advance(600)
    #expect(store.beginSummon() == true)
}

@Test func freshAt601Seconds() {
    let clock = TestClock()
    var store = storeWithTurn(clock)
    clock.advance(601)
    #expect(store.beginSummon() == false)
    #expect(store.turns.isEmpty)
    #expect(store.messages.isEmpty)
}

@Test func touchExtendsTheWindow() {
    let clock = TestClock()
    var store = storeWithTurn(clock)
    clock.advance(500)
    store.touch()
    clock.advance(500)
    #expect(store.beginSummon() == true)
}

@Test func resetClears() {
    let clock = TestClock()
    var store = storeWithTurn(clock)
    store.reset()
    #expect(store.turns.isEmpty)
    #expect(store.lastInteraction == nil)
    #expect(store.beginSummon() == false)
}
