import AppKit
import CompanionCore
@testable import CompanionSession
import CompanionTestSupport
import CompanionUI
import Testing

private let slowEvents: [LLMStreamEvent] = [.textDelta("Hel"), .textDelta("lo"), .finished(stopReason: "end_turn")]

private func slowProvider() -> FakeLLMProvider {
    FakeLLMProvider(events: slowEvents, delayPerEvent: .milliseconds(100))
}

@MainActor @Suite struct SummonCoordinatorTests {
    @Test func showsAtCursorAvoidingCentredRect() {
        let h = Harness()
        h.coordinator.summon()
        #expect(h.presenter.showCalls.map(\.avoiding) == [nil])
        #expect(h.presenter.showCalls.first?.cursor == NSPoint(x: 500, y: 400))
        #expect(h.trace.records.last?.offsets[.panelVisible] != nil)
    }

    @Test func doubleSummonMidAnswerFocusesOnly() async {
        let slow = slowProvider()
        let h = Harness(providers: FakeProviders(fallback: slow))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.vm.thread.last?.markdown == "Hel" }
        h.coordinator.summon()
        #expect(h.presenter.showCalls.count == 1 && h.presenter.focusCount == 1 && h.trace.records.count == 1)
        await h.coordinator.settle()
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hello"] && slow.requests.count == 1)
    }

    @Test func firstRunWithoutKeyOrPermissions() async {
        let h = Harness(providers: FakeProviders(), permissions: FakePermissions(screenRecording: false, accessibility: false))
        h.providers.missingKeyProviders = ["anthropic"]
        h.coordinator.summon()
        #expect(h.presenter.showCalls.count == 1)
        await h.coordinator.settle()
        #expect(h.vm.error == BubbleErrorBanner(message: "Add your Anthropic API key in Settings to start asking.", offerModelSwitch: false, offerSettings: true))
        h.coordinator.bubbleDidSubmit("what is a derivative?")
        #expect(h.vm.thread.isEmpty && h.vm.isBusy == false && h.provider.requests.isEmpty)
        h.coordinator.bubbleDidRequestSettings()
        #expect(h.openSettingsCount == 1 && h.permissions.opened.isEmpty)
        h.providers.missingKeyProviders = []
        h.coordinator.bubbleDidClose()
        h.coordinator.summon()
        await h.coordinator.settle()
        #expect(h.vm.error?.message == "Companion can't see your screen yet. Grant Screen Recording in System Settings.")
        h.coordinator.bubbleDidRequestSettings()
        #expect(h.permissions.opened == [.screenRecording])
        await h.submit("q")
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hello"])
    }

    @Test func accessibilityBannerOpensItsOwnPane() async {
        let h = Harness(permissions: FakePermissions(screenRecording: true, accessibility: false))
        h.coordinator.summon()
        await h.coordinator.settle()
        #expect(h.vm.error?.message == "Companion can't read text in other apps yet. Grant Accessibility in System Settings.")
        h.coordinator.bubbleDidRequestSettings()
        #expect(h.permissions.opened == [.accessibility] && h.openSettingsCount == 0)
    }

    @Test func deltasStreamInOrder() async {
        let provider = FakeLLMProvider(events: [.textDelta("a"), .textDelta("b"), .textDelta("c"), .finished(stopReason: "end_turn")])
        let h = Harness(providers: FakeProviders(fallback: provider))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        #expect(h.vm.steps.map(\.text) == ["Reading screen…"])
        await h.coordinator.settle()
        #expect(h.vm.thread.last?.markdown == "abc" && h.vm.thread.last?.isStreaming == false)
        #expect(h.vm.isBusy == false && h.vm.steps.isEmpty)
        let offsets = h.trace.records.last?.offsets ?? [:]
        #expect(offsets[.submit] != nil && offsets[.firstToken] != nil && offsets[.finished] != nil)
        #expect(h.coordinator.conversation.turns.count == 1)
        #expect(h.coordinator.conversation.turns[0].userMessage == provider.requests[0].messages.last)
    }

    @Test func resumeWithin600Seconds() async {
        let h = Harness()
        h.coordinator.summon()
        await h.submit("q1")
        h.coordinator.bubbleDidClose()
        h.clock.advance(599)
        h.coordinator.summon()
        #expect(h.vm.thread.map(\.markdown) == ["q1", "Hello"])
        await h.submit("q2")
        #expect(h.provider.requests.last?.messages.count == 3)
        h.coordinator.bubbleDidClose()
        h.clock.advance(601)
        h.coordinator.summon()
        #expect(h.vm.thread.isEmpty)
        await h.submit("q3")
        #expect(h.provider.requests.last?.messages.count == 1)
    }

    @Test func tabOverrideAppliesToOneQuestion() async {
        let h = Harness()
        h.coordinator.summon()
        #expect(h.vm.modelName == "Haiku 4.5")
        h.coordinator.bubbleDidRequestModelCycle()
        #expect(h.vm.modelName == "Sonnet 5.5")
        await h.submit("q1")
        #expect(h.vm.modelName == "Haiku 4.5")
        await h.submit("q2")
        #expect(h.provider.requests.map(\.model) == [ModelCatalog.sonnet55, ModelCatalog.haiku45])
    }

    @Test func closeMidStreamCancelsAndKeepsPartial() async {
        let h = Harness(providers: FakeProviders(fallback: FakeLLMProvider(
            events: [.textDelta("Part"), .textDelta("ial"), .finished(stopReason: nil)], delayPerEvent: .milliseconds(200))))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.vm.thread.last?.markdown == "Part" }
        h.coordinator.bubbleDidClose()
        await h.coordinator.settle()
        #expect(h.presenter.hideCount == 1)
        #expect(h.vm.thread.last?.markdown == "Part" && h.vm.thread.last?.isStreaming == false)
        #expect(h.coordinator.conversation.turns.map(\.answer) == ["Part"])
    }

    /// The partial must already be stored when a summon follows in the same main-actor turn.
    @Test func closeThenImmediateSummonResumesPartial() async {
        let h = Harness(providers: FakeProviders(fallback: slowProvider()))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.vm.thread.last?.markdown == "Hel" }
        h.coordinator.bubbleDidClose()
        h.coordinator.summon()
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hel"] && h.vm.isBusy == false)
        await h.coordinator.settle()
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hel"])
    }

    @Test func summonWhileHiddenSettlesALiveRun() async {
        let h = Harness(providers: FakeProviders(fallback: slowProvider()))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.vm.thread.last?.markdown == "Hel" }
        h.presenter.vanishWithoutClose()
        h.coordinator.summon()
        #expect(h.vm.isBusy == false)
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hel"])
        #expect(h.coordinator.conversation.turns.map(\.answer) == ["Hel"])
        await h.coordinator.settle()
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hel"])
        #expect(h.coordinator.conversation.turns.map(\.answer) == ["Hel"])
    }

    @Test func overloadedOffersModelSwitchAndRetries() async {
        let h = Harness(providers: FakeProviders([ModelCatalog.haiku45.modelID: FakeLLMProvider(failure: LLMError.http(status: 529, message: "Overloaded"))]))
        h.coordinator.summon()
        await h.submit("q")
        #expect(h.vm.error == BubbleErrorBanner(message: "Haiku 4.5 is overloaded right now. Switch models or try again.", offerModelSwitch: true, offerSettings: false))
        #expect(h.vm.isBusy == false && h.coordinator.conversation.turns.isEmpty)
        h.coordinator.bubbleDidRequestModelSwitchAfterError()
        await h.coordinator.settle()
        #expect(h.vm.error == nil)
        #expect(h.provider.requests.map(\.model) == [ModelCatalog.sonnet55])
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hello"])
    }

    @Test func settingsChangeMidStreamAffectsNextQuestionOnly() async {
        let slow = slowProvider()
        let h = Harness(providers: FakeProviders(fallback: slow))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q1")
        await waitUntil { h.vm.thread.last?.markdown == "Hel" }
        h.settings.update { $0.routing.genericWindow = ModelCatalog.sonnet55 }
        await h.coordinator.settle()
        #expect(h.vm.thread.last?.markdown == "Hello")
        await h.submit("q2")
        #expect(slow.requests.map(\.model) == [ModelCatalog.haiku45, ModelCatalog.sonnet55])
    }

    @Test func blankOrBusySubmitIsIgnored() async {
        let h = Harness()
        h.coordinator.summon()
        await h.submit("  \n")
        #expect(h.provider.requests.isEmpty)
        h.coordinator.bubbleDidSubmit("q1")
        h.coordinator.bubbleDidSubmit("q2")
        await h.coordinator.settle()
        #expect(h.provider.requests.count == 1)
    }

    /// The view model clears its input right after `bubbleDidSubmit`, so a question the coordinator
    /// refuses would otherwise vanish.
    @Test func refusedQuestionGoesBackInTheInput() async {
        let h = Harness(providers: FakeProviders(fallback: slowProvider()))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q1")
        h.coordinator.bubbleDidSubmit("typed while busy")
        h.vm.inputText = ""
        await waitUntil { h.vm.inputText == "typed while busy" }
        h.vm.inputText = ""
        await h.coordinator.settle()
        h.providers.missingKeyProviders = ["anthropic"]
        h.coordinator.bubbleDidSubmit("no key yet")
        h.vm.inputText = ""
        await waitUntil { h.vm.inputText == "no key yet" }
    }

    @Test func newChatMidStreamClearsEverything() async {
        let h = Harness(providers: FakeProviders(fallback: slowProvider()))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.vm.thread.last?.markdown == "Hel" }
        h.coordinator.bubbleDidRequestNewChat()
        #expect(h.vm.thread.isEmpty && h.coordinator.conversation.turns.isEmpty && h.vm.isBusy == false)
        await h.coordinator.settle()
        #expect(h.vm.thread.isEmpty && h.coordinator.conversation.turns.isEmpty)
    }

    @Test func hintToggleChangesPrompt() async {
        let h = Harness()
        h.coordinator.summon()
        await h.submit("q1")
        h.coordinator.bubbleDidToggleHint()
        #expect(h.vm.hintMode == true)
        await h.submit("q2")
        #expect(h.provider.requests[0].system != h.provider.requests[1].system)
    }

    /// An answerless stream must not leave a blank bubble, or store an empty turn.
    @Test func emptyAnswerShowsAnErrorAndStoresNoTurn() async {
        let h = Harness(providers: FakeProviders(fallback: FakeLLMProvider(events: [.finished(stopReason: "end_turn")])))
        h.coordinator.summon()
        await h.submit("q")
        #expect(h.vm.error?.message == "Got an unreadable reply from Haiku 4.5. Try again.")
        #expect(h.vm.steps.isEmpty && h.vm.isBusy == false && h.coordinator.conversation.turns.isEmpty)
    }

    @Test func removingAChipRemovesItFromTheContext() {
        let h = Harness()
        let item = ContextItem(piece: .focusedText("x"))
        h.coordinator.applyContext(CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow, items: [item], isComplete: true))
        h.coordinator.bubbleDidRemoveContextItem(item.id)
        #expect(h.vm.context?.items.isEmpty == true && h.coordinator.context?.items.isEmpty == true)
    }
}
