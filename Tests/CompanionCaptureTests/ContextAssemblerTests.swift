import Testing
import Foundation
import CompanionCore
@testable import CompanionCapture

private func snap(front: FrontAppInfo? = dia, privacy: PrivacyDecision = .allowed, isBrowser: Bool = true,
                  extensionConnected: Bool = true, windowImage: ImageAttachment? = img, regionImage: ImageAttachment? = nil,
                  selectedText: String? = nil, focusedText: String? = nil, tab: TabContext? = nil,
                  itemIDs: ItemIDs = ItemIDs()) -> SummonSnapshot {
    SummonSnapshot(front: front, privacy: privacy, isBrowser: isBrowser, extensionConnected: extensionConnected,
                   windowImage: windowImage, regionImage: regionImage, selectedText: selectedText,
                   focusedText: focusedText, tab: tab, itemIDs: itemIDs)
}

@Test func youtubeTab() throws {
    let c = ContextAssembler.assemble(snap(tab: try tabFixture("ext-tabContext-youtube.json")))
    #expect(c.kind == .youtube && c.chips == ["window", "▶ 12:41 · Finding the roots", "transcript 9:41–12:41"])
    #expect(c.tabId == 12)
}
@Test func mathTab() throws {
    let c = ContextAssembler.assemble(snap(tab: try tabFixture("ext-tabContext-math.json")))
    #expect(c.kind == .mathPage && c.chips == ["window", "page text", "math ×2"])
}
@Test func classroomTab() throws {
    let c = ContextAssembler.assemble(snap(tab: try tabFixture("ext-tabContext-classroom.json")))
    #expect(c.kind == .webPage && c.chips == ["window", "page text"])
}
@Test func blockedContextCarriesOnlyTheNotice() throws {
    let framed = FrontAppInfo(bundleID: dia.bundleID, appName: "Dia", pid: 4242, windowTitle: "Chase - Dashboard", windowFrame: R(0, 0, 800, 600))
    let c = ContextAssembler.assemble(snap(front: framed, privacy: siteBlocked, selectedText: "acct 1234", focusedText: "x",
                                           tab: try tabFixture("ext-tabContext-youtube.json")))
    #expect(c.pieces == [.notice(.contextOffForSite)] && c.kind == .genericWindow)
    #expect(c.front?.bundleID == dia.bundleID && c.front?.windowTitle == nil && c.front?.windowFrame == nil)
    #expect(c.tabId == nil)
}
@Test func blockedAppUsesTheAppNotice() {
    let c = ContextAssembler.assemble(snap(front: onePassword, privacy: .blocked(reason: "1Password is on your blocklist"), isBrowser: false))
    #expect(c.pieces == [.notice(.contextOffForApp)])
}
@Test func regionWinsKindAndReplacesWindowImage() throws {
    let c = ContextAssembler.assemble(snap(regionImage: img, tab: try tabFixture("ext-tabContext-youtube.json")))
    #expect(c.kind == .region && c.chips.first == "region" && !c.chips.contains("window"))
}
@Test func noticesOrderAndRules() {
    let a = ContextAssembler.assemble(snap(privacy: .siteUnchecked, extensionConnected: false))
    #expect(Array(a.chips.suffix(2)) == ["site not checked", "extension not connected"])
    let b = ContextAssembler.assemble(snap(front: preview, isBrowser: false, extensionConnected: false))
    #expect(!b.chips.contains("extension not connected"))
}
@Test func transcriptItemRules() throws {
    func video(_ status: TranscriptStatus, playhead: Double = 761, keep: Bool = false) throws -> CapturedContext {
        var tab = try tabFixture("ext-tabContext-youtube.json")
        tab.youtube?.transcriptStatus = status
        tab.youtube?.playheadSeconds = playhead
        if !keep { tab.youtube?.transcript = [] }
        return ContextAssembler.assemble(snap(tab: tab))
    }
    let unavailable = try video(.unavailable)
    #expect(unavailable.chips.contains("no captions") && !unavailable.chips.contains { $0.hasPrefix("transcript") })
    let loading = try video(.loading)
    #expect(!loading.chips.contains("no captions") && !loading.chips.contains { $0.hasPrefix("transcript") })
    let past = try video(.available, playhead: 3000, keep: true)
    #expect(!past.chips.contains { $0.hasPrefix("transcript") })
    // The full transcript stays inside the video item for WS1.
    #expect(past.pieces.contains { if case .youtubeVideo(let v) = $0 { v.transcript.count == 3 } else { false } })
}
@Test func textRules() {
    let long = String(repeating: "a", count: 10_000)
    let capped = ContextAssembler.assemble(snap(focusedText: long))
    #expect(capped.pieces.contains { if case .focusedText(let t) = $0 { t.count == 8_000 } else { false } })
    #expect(ContextAssembler.assemble(snap(selectedText: "same", focusedText: "same")).chips == ["window", "selection"])
    #expect(!ContextAssembler.assemble(snap(selectedText: "  \n")).chips.contains("selection"))
    #expect(ContextAssembler.assemble(snap(selectedText: "s", focusedText: "f")).chips == ["window", "selection", "screen text"])
}
@Test func pageCaps() throws {
    var tab = try tabFixture("ext-tabContext-math.json")
    tab.page?.math = []
    tab.page?.visibleText = ""
    let empty = ContextAssembler.assemble(snap(tab: tab))
    #expect(!empty.chips.contains("page text") && empty.kind == .webPage)
    tab.page?.visibleText = String(repeating: "b", count: 25_000)
    tab.page?.math = Array(repeating: MathSnippet(format: .latex, source: "x"), count: 60)
    let big = ContextAssembler.assemble(snap(tab: tab))
    #expect(big.pieces.contains { if case .webPage(let p) = $0 { p.visibleText.count == 20_000 } else { false } })
    #expect(big.chips.contains("math ×50"))
}
@Test func genericWindow() {
    let c = ContextAssembler.assemble(snap(front: preview, isBrowser: false))
    #expect(c.kind == .genericWindow && c.chips == ["window"] && c.tabId == nil)
}
@Test func idsStableAcrossEmissions() {
    let ids = ItemIDs()
    let a = ContextAssembler.assemble(snap(front: preview, isBrowser: false, itemIDs: ids))
    let b = ContextAssembler.assemble(snap(front: preview, isBrowser: false, selectedText: "s", itemIDs: ids))
    #expect(a.items[0].id == b.items[0].id && a.items[0].id == ids.image)
}
