import AppKit
import CompanionCapture
import CompanionCore
@testable import CompanionSession
import CompanionTestSupport
import CompanionUI
import Testing

private func requestText(_ message: LLMMessage?) -> [String] {
    (message?.content ?? []).compactMap { if case .text(let text) = $0 { text } else { nil } }
}

@MainActor @Suite struct SummonContextTests {
    @Test func gatherFeedsChipsGlowAndPrewarm() async {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let text = ContextItem(piece: .focusedText("x^2 - 5x + 6 = 0"))
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(items: [text], complete: false),
                                                           ctx(kind: .mathPage, items: [text], complete: true)]))
        h.coordinator.summon()
        await h.coordinator.settle()
        #expect(await h.gatherer.requests == [.frontWindow])
        #expect(h.vm.context?.isComplete == true && h.glow.flashed == [frame])
        #expect(h.provider.prewarmCount == 1)
        #expect(h.vm.modelName == "Sonnet 5.5")
        #expect(h.trace.records.last?.offsets[.contextFirst] != nil && h.trace.records.last?.offsets[.contextComplete] != nil)
    }

    @Test func blockedAppGetsNoGlow() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: true, privacy: .blocked(reason: "app"))]))
        h.coordinator.summon()
        await h.coordinator.settle()
        #expect(h.glow.flashed.isEmpty)
    }

    @Test func tabOverrideSurvivesGatherEmissions() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(kind: .mathPage, complete: true)], gap: .milliseconds(50)))
        h.coordinator.summon()
        h.coordinator.bubbleDidRequestModelCycle()
        await h.coordinator.settle()
        #expect(h.vm.modelName == "Sonnet 5.5")
    }

    @Test func doubleSummonDoesNotRegather() async {
        let slow = FakeLLMProvider(events: [.textDelta("Hel"), .textDelta("lo"), .finished(stopReason: nil)], delayPerEvent: .milliseconds(100))
        let h = Harness(providers: FakeProviders(fallback: slow), gatherer: FakeGatherer(emissions: [ctx(complete: true)]))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.vm.thread.last?.markdown == "Hel" }
        h.coordinator.summon()
        await h.coordinator.settle()
        #expect(await h.gatherer.requests == [.frontWindow])
        #expect(h.vm.thread.last?.markdown == "Hello" && h.glow.flashed.count == 1)
    }

    @Test func removedChipStaysRemovedAndIsNotSent() async {
        let secret = ContextItem(piece: .selectedText("SECRET-A"))
        let keep = ContextItem(piece: .focusedText("keep me"))
        let h = Harness(gatherer: FakeGatherer(emissions: [
            ctx(items: [secret, keep], complete: false),
            ctx(items: [ContextItem(piece: .selectedText("SECRET-A")), ContextItem(piece: .focusedText("keep me"))], complete: true),
        ], gap: .milliseconds(50)))
        h.coordinator.summon()
        await waitUntil { h.coordinator.context?.items.count == 2 }
        h.coordinator.bubbleDidRemoveContextItem(secret.id)
        await h.coordinator.settle()
        #expect(h.vm.context?.isComplete == true)
        #expect(h.vm.context?.items.contains { if case .selectedText = $0.piece { true } else { false } } == false)
        await h.submit("q")
        let sent = requestText(h.provider.requests.last?.messages.last)
        #expect(!sent.contains { $0.contains("SECRET-A") })
        #expect(sent.contains { $0.contains("keep me") })
    }

    @Test func submitWaitsBrieflyForGather() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [
            ctx(complete: false),
            ctx(items: [ContextItem(piece: .focusedText("late"))], complete: true),
        ], gap: .milliseconds(200)))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await h.coordinator.settle()
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("late") })
    }

    @Test func submitStopsWaitingForAStuckGatherAfter500ms() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [
            ctx(complete: false),
            ctx(items: [ContextItem(piece: .focusedText("too late"))], complete: true),
        ], gap: .seconds(2)))
        h.coordinator.summon()
        let start = ContinuousClock.now
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { !h.provider.requests.isEmpty }
        #expect(ContinuousClock.now - start < .milliseconds(1500))
        #expect(!requestText(h.provider.requests.last?.messages.last).contains { $0.contains("too late") })
        h.coordinator.bubbleDidClose()
    }

    @Test func regionEscapeChangesNothing() async {
        let h = Harness()
        h.coordinator.summonRegion()
        await waitUntil { h.selector.selectCount == 1 }
        h.selector.finish(nil)
        await h.coordinator.settle()
        #expect(h.presenter.showCalls.isEmpty)
        #expect(await h.gatherer.requests.isEmpty)
        #expect(h.trace.records.isEmpty)
    }

    @Test func regionSelectionAvoidsAndGathersRegion() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(kind: .region, complete: true)]))
        h.coordinator.summonRegion()
        await waitUntil { h.selector.selectCount == 1 }
        let selection = RegionSelection(rect: CGRect(x: 200, y: 150, width: 400, height: 300), displayID: 1)
        h.selector.finish(selection)
        await h.coordinator.settle()
        #expect(h.presenter.showCalls[0].avoiding == selection.rect)
        #expect(h.glow.flashed == [selection.rect])
        #expect(await h.gatherer.requests == [.region(selection)])
    }

    @Test func regionWhileVisibleKeepsThreadAndFocuses() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(kind: .region, complete: true)]))
        h.coordinator.summon()
        await h.submit("q")
        h.coordinator.summonRegion()
        await waitUntil { h.selector.selectCount == 1 }
        h.selector.finish(RegionSelection(rect: CGRect(x: 1, y: 1, width: 10, height: 10), displayID: 1))
        await h.coordinator.settle()
        #expect(h.presenter.showCalls.count == 1 && h.presenter.focusCount == 1)
        #expect(h.vm.thread.map(\.markdown) == ["q", "Hello"])
    }

    @Test func hotkeysIgnoredDuringRegionSelection() async {
        let h = Harness()
        h.coordinator.summonRegion()
        await waitUntil { h.selector.selectCount == 1 }
        h.coordinator.summon()
        h.coordinator.summonRegion()
        #expect(h.presenter.showCalls.isEmpty && h.selector.selectCount == 1)
        h.selector.finish(nil)
        await h.coordinator.settle()
        #expect(h.presenter.showCalls.isEmpty)
    }

    @Test func closeCancelsGather() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [
            ctx(complete: false),
            ctx(items: [ContextItem(piece: .focusedText("late"))], complete: true),
        ], gap: .milliseconds(100)))
        h.coordinator.summon()
        await waitUntil { h.coordinator.context != nil }
        h.coordinator.bubbleDidClose()
        await h.coordinator.settle()
        #expect(h.coordinator.context?.isComplete == false)
    }
}
