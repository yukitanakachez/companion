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
    @Test func summonCapturesNothing() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: true)]))
        h.coordinator.summon()
        await h.coordinator.settle()
        #expect(h.presenter.showCalls.count == 1)
        #expect(await h.gatherer.requests.isEmpty)
        #expect(h.glow.flashed.isEmpty && h.vm.context == nil)
        #expect(h.provider.prewarmCount == 1 && h.providers.resolved.first == ModelCatalog.haiku45)
        #expect(h.vm.modelName == "Haiku 4.5")
        #expect(h.trace.records.last?.offsets[.contextFirst] == nil)
    }

    @Test func submitFeedsChipsGlowAndRouting() async {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let text = ContextItem(piece: .focusedText("x^2 - 5x + 6 = 0"))
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(items: [text], complete: false),
                                                           ctx(kind: .mathPage, items: [text], complete: true)]))
        h.coordinator.summon()
        await h.submit("q")
        #expect(await h.gatherer.requests == [.frontWindow])
        #expect(h.vm.context?.isComplete == true && h.glow.flashed == [frame])
        #expect(h.provider.requests.map(\.model) == [ModelCatalog.sonnet55])   // routed from this capture
        #expect(h.vm.modelName == "Sonnet 5.5")
    }

    @Test func contextMarksFallAfterSubmit() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(complete: true)]))
        h.coordinator.summon()
        await h.submit("q")
        let offsets = h.trace.records.last?.offsets ?? [:]
        #expect(offsets[.submit]! <= offsets[.contextFirst]!)
        #expect(offsets[.contextFirst]! <= offsets[.contextComplete]!)
        #expect(offsets[.contextComplete]! <= offsets[.firstToken]!)
    }

    @Test func everyQuestionCapturesAfresh() async {
        let first = ctx(items: [ContextItem(piece: .focusedText("FIRST-TAB"))], complete: true)
        let second = ctx(items: [ContextItem(piece: .focusedText("SECOND-TAB"))], complete: true)
        let h = Harness(gatherer: FakeGatherer(emissions: [first]))
        h.coordinator.summon()
        await h.submit("q1")
        await h.gatherer.setEmissions([second])
        await h.submit("q2")
        #expect(await h.gatherer.requests == [.frontWindow, .frontWindow])
        #expect(h.glow.flashed.count == 2)
        let sent = requestText(h.provider.requests.last?.messages.last)
        #expect(sent.contains { $0.contains("SECOND-TAB") } && !sent.contains { $0.contains("FIRST-TAB") })
    }

    @Test func aLiveStepShowsWhileTheCaptureLands() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(complete: true)], gap: .milliseconds(100)))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        #expect(h.vm.steps.map(\.text) == ["Reading screen…"] && h.vm.steps.first?.state == .active)
        #expect(h.provider.requests.isEmpty)
        await h.coordinator.settle()
        #expect(h.vm.steps.isEmpty && h.vm.thread.last?.markdown == "Hello")
    }

    @Test func busySubmitDoesNotCapture() async {
        let h = Harness(providers: FakeProviders(fallback: FakeLLMProvider(events: [.textDelta("a"), .finished(stopReason: nil)], delayPerEvent: .milliseconds(100))),
                        gatherer: FakeGatherer(emissions: [ctx(complete: true)]))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q1")
        h.coordinator.bubbleDidSubmit("q2")
        await h.coordinator.settle()
        #expect(await h.gatherer.requests == [.frontWindow])
    }

    @Test func blockedAppGetsNoGlowAndSendsOnlyItsNotice() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(items: [ContextItem(piece: .notice(.contextOffForApp))], complete: true, privacy: .blocked(reason: "app"))]))
        h.coordinator.summon()
        await h.submit("q")
        #expect(h.glow.flashed.isEmpty)
        #expect(h.vm.context?.items.count == 1)
        #expect(h.provider.requests.last?.messages.last?.content.contains { if case .image = $0 { true } else { false } } == false)
    }

    @Test func tabOverrideSurvivesTheCapture() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(complete: true)], gap: .milliseconds(50)))
        h.coordinator.summon()
        h.coordinator.bubbleDidRequestModelCycle()
        await h.submit("q")
        #expect(h.provider.requests.map(\.model) == [ModelCatalog.sonnet55])   // a generic window alone routes to Haiku
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

    @Test func removedChipStaysRemovedAcrossEmissionsOfOneCapture() async {
        let secret = ContextItem(piece: .selectedText("SECRET-A"))
        let keep = ContextItem(piece: .focusedText("keep me"))
        let h = Harness(providers: FakeProviders(fallback: FakeLLMProvider(events: [.textDelta("a"), .finished(stopReason: nil)], delayPerEvent: .milliseconds(100))),
                        gatherer: FakeGatherer(emissions: [
                            ctx(items: [secret, keep], complete: false),
                            ctx(items: [ContextItem(piece: .selectedText("SECRET-A")), ContextItem(piece: .focusedText("keep me"))], complete: true),
                        ], gap: .milliseconds(100)))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.coordinator.context?.items.count == 2 }
        h.coordinator.bubbleDidRemoveContextItem(secret.id)
        await h.coordinator.settle()
        #expect(h.vm.context?.isComplete == true)
        #expect(h.vm.context?.items.contains { if case .selectedText = $0.piece { true } else { false } } == false)
        let sent = requestText(h.provider.requests.last?.messages.last)
        #expect(!sent.contains { $0.contains("SECRET-A") })
        #expect(sent.contains { $0.contains("keep me") })
    }

    private func secretHarness() async -> Harness {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(items: [ContextItem(piece: .selectedText("SECRET-A")), ContextItem(piece: .focusedText("keep me"))], complete: true)]))
        h.coordinator.summon()
        await h.submit("q1")
        let chip = h.vm.context?.items.first { if case .selectedText = $0.piece { true } else { false } }
        h.coordinator.bubbleDidRemoveContextItem(chip!.id)
        return h
    }

    @Test func aRemovedKindIsExcludedFromLaterCaptures() async {
        let h = await secretHarness()
        await h.submit("q2")
        let sent = requestText(h.provider.requests.last?.messages.last)
        #expect(!sent.contains { $0.contains("SECRET-A") } && sent.contains { $0.contains("keep me") })
    }

    @Test func closingForgetsRemovedKinds() async {
        let h = await secretHarness()
        h.coordinator.bubbleDidClose()
        h.coordinator.summon()
        await h.submit("q2")
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("SECRET-A") })
    }

    @Test func newChatForgetsRemovedKindsAndClearsChips() async {
        let h = await secretHarness()
        h.coordinator.bubbleDidRequestNewChat()
        #expect(h.vm.context == nil)
        await h.submit("q2")
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("SECRET-A") })
    }

    @Test func submitWaitsBrieflyForTheCapture() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [
            ctx(complete: false),
            ctx(items: [ContextItem(piece: .focusedText("late"))], complete: true),
        ], gap: .milliseconds(200)))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        await h.coordinator.settle()
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("late") })
    }

    /// The chips show what was used: a piece landing after the limit was not sent, so it gets no chip.
    @Test func submitStopsWaitingForAStuckCaptureAfter500ms() async {
        let h = Harness(providers: FakeProviders(fallback: FakeLLMProvider(events: [.textDelta("a"), .finished(stopReason: nil)], delayPerEvent: .milliseconds(700))),
                        gatherer: FakeGatherer(emissions: [
                            ctx(complete: false),
                            ctx(items: [ContextItem(piece: .focusedText("too late"))], complete: true),
                        ], gap: .milliseconds(600)))
        h.coordinator.summon()
        let start = ContinuousClock.now
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { !h.provider.requests.isEmpty }
        #expect(ContinuousClock.now - start < .milliseconds(1500))
        #expect(!requestText(h.provider.requests.last?.messages.last).contains { $0.contains("too late") })
        await h.coordinator.settle()
        #expect(h.vm.context?.items.isEmpty == true)
    }

    private func companionFront(_ h: Harness) -> CapturedContext {
        ctx(complete: true, bundleID: h.coordinator.ownBundleID)
    }

    @Test func aCaptureOfCompanionItselfKeepsThePreviousContext() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(items: [ContextItem(piece: .focusedText("from Notes"))], complete: true)]))
        h.coordinator.summon()
        await h.submit("q1")
        await h.gatherer.setEmissions([companionFront(h)])
        await h.submit("q2")
        #expect(h.glow.flashed.count == 1)
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("from Notes") })
        #expect(h.vm.context?.front?.bundleID == "com.apple.Notes")
    }

    /// The live resolver skips Companion and reports nil when no other app has a window.
    @Test func aCaptureWithNoFrontAppKeepsThePreviousContext() async {
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(items: [ContextItem(piece: .focusedText("from Notes"))], complete: true)]))
        h.coordinator.summon()
        await h.submit("q1")
        await h.gatherer.setEmissions([CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow, items: [], isComplete: true)])
        await h.submit("q2")
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("from Notes") })
    }

    /// Selecting a region can leave Companion frontmost; the region is still what the user asked for.
    @Test func aRegionIsKeptEvenWhenCompanionIsFront() async {
        let image = ContextItem(piece: .focusedText("REGION"))
        let h = Harness()
        await h.gatherer.setEmissions([ctx(kind: .region, items: [image], complete: true, bundleID: h.coordinator.ownBundleID)])
        await selectRegion(h)
        await h.submit("q")
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("REGION") })
    }

    private func selectRegion(_ h: Harness, _ rect: CGRect = CGRect(x: 200, y: 150, width: 400, height: 300)) async {
        let count = h.selector.selectCount
        h.coordinator.summonRegion()
        await waitUntil { h.selector.selectCount == count + 1 }
        h.selector.finish(RegionSelection(rect: rect, displayID: 1))
        await h.coordinator.settle()
    }

    @Test func aRegionIsTheContextForFollowUpsUntilTheBubbleCloses() async {
        let region = ctx(kind: .region, items: [ContextItem(piece: .focusedText("REGION"))], complete: true)
        let h = Harness(gatherer: FakeGatherer(emissions: [region]))
        await selectRegion(h)
        await h.submit("q1")
        await h.submit("q2")
        #expect(await h.gatherer.requests.count == 1)
        #expect(h.glow.flashed.count == 1)
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("REGION") })

        h.coordinator.bubbleDidClose()
        h.coordinator.summon()
        await h.gatherer.setEmissions([ctx(items: [ContextItem(piece: .focusedText("WINDOW"))], complete: true)])
        await h.submit("q3")
        #expect(await h.gatherer.requests.last == .frontWindow)
        #expect(requestText(h.provider.requests.last?.messages.last).contains { $0.contains("WINDOW") })
    }

    @Test func aNewRegionReplacesTheOldOneEvenAfterARegionChipWasRemoved() async {
        let first = ContextItem(piece: .regionImage(Fixtures.samplePNG()))
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(kind: .region, items: [first], complete: true)]))
        await selectRegion(h)
        h.coordinator.bubbleDidRemoveContextItem(first.id)
        let second = ContextItem(piece: .regionImage(Fixtures.samplePNG()))
        await h.gatherer.setEmissions([ctx(kind: .region, items: [second], complete: true)])
        await selectRegion(h, CGRect(x: 1, y: 1, width: 10, height: 10))
        #expect(h.vm.context?.items.map(\.id) == [second.id])
    }

    @Test func aRegionSelectedDuringTheWaitIsNotCutShort() async {
        let late = ContextItem(piece: .focusedText("REGION-LATE"))
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(kind: .region, complete: false), ctx(kind: .region, items: [late], complete: true)], gap: .milliseconds(650)))
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("q")
        h.coordinator.summonRegion()
        await waitUntil { h.selector.selectCount == 1 }
        h.selector.finish(RegionSelection(rect: CGRect(x: 1, y: 1, width: 10, height: 10), displayID: 1))
        await h.coordinator.settle()
        #expect(h.vm.context?.items.map(\.id) == [late.id])
    }

    @Test func removingTheRegionChipGoesBackToCaptureOnSend() async {
        let region = ContextItem(piece: .regionImage(Fixtures.samplePNG()))
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(kind: .region, items: [region], complete: true)]))
        await selectRegion(h)
        h.coordinator.bubbleDidRemoveContextItem(region.id)
        await h.gatherer.setEmissions([ctx(complete: true)])
        await h.submit("q")
        #expect(await h.gatherer.requests.last == .frontWindow)
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
        h.coordinator.bubbleDidSubmit("q")
        await waitUntil { h.coordinator.context != nil }
        h.coordinator.bubbleDidClose()
        await h.coordinator.settle()
        #expect(h.coordinator.context?.isComplete == false)
    }
}
