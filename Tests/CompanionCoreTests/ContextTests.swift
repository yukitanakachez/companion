import CoreGraphics
import Foundation
import Testing
import CompanionCore

@Test func timestamps() {
    #expect(formatTimestamp(761) == "12:41")
    #expect(formatTimestamp(581.2) == "9:41")
    #expect(formatTimestamp(3725) == "1:02:05")
    #expect(formatTimestamp(0) == "0:00")
    #expect(formatTimestamp(-5) == "0:00")
}

@Test func timestampsSurviveNonFiniteValues() {
    #expect(formatTimestamp(.nan) == "0:00")
    #expect(formatTimestamp(.infinity) == "0:00")
}

@Test func chipLabels() {
    let img = ImageAttachment(png: Data([1]), pixelWidth: 1, pixelHeight: 1)
    let yt = YouTubeContext(videoId: "abc123XYZ00", title: "Solving Quadratics", channel: nil,
                            chapter: "Finding the roots", playheadSeconds: 761, durationSeconds: 1450,
                            transcriptStatus: .available, transcript: [])
    #expect(ContextItem(piece: .windowImage(img)).chipLabel == "window")
    #expect(ContextItem(piece: .regionImage(img)).chipLabel == "region")
    #expect(ContextItem(piece: .youtubeVideo(yt)).chipLabel == "▶ 12:41 · Finding the roots")
    #expect(ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761)).chipLabel == "transcript 9:41–12:41")
    #expect(ContextItem(piece: .math([MathSnippet(format: .latex, source: "x"), MathSnippet(format: .latex, source: "y")])).chipLabel == "math ×2")
    #expect(ContextItem(piece: .selectedText("hi")).chipLabel == "selection")
    #expect(ContextItem(piece: .focusedText("hi")).chipLabel == "screen text")
    #expect(ContextItem(piece: .notice(.siteNotChecked)).chipLabel == "site not checked")
    #expect(ContextItem(piece: .notice(.extensionNotConnected)).isRemovable == false)
    #expect(ContextItem(piece: .selectedText("hi")).isRemovable == true)
    let page = WebPageContext(url: "https://a.test", title: "A", visibleText: "t", math: [])
    #expect(ContextItem(piece: .webPage(page)).chipLabel == "page text")
}

@Test func youtubeChipChapterVariants() {
    func yt(_ chapter: String?) -> ContextItem {
        ContextItem(piece: .youtubeVideo(YouTubeContext(
            videoId: "v", title: "t", channel: nil, chapter: chapter, playheadSeconds: 761,
            durationSeconds: nil, transcriptStatus: .loading, transcript: [])))
    }
    #expect(yt(nil).chipLabel == "▶ 12:41")
    #expect(yt("123456789012345678901234").chipLabel == "▶ 12:41 · 123456789012345678901234")
    #expect(yt("123456789012345678901234567").chipLabel == "▶ 12:41 · 123456789012345678901234")
}

@Test func noticeLabels() {
    #expect(ContextNotice.contextOffForApp.label == "context off for this app")
    #expect(ContextNotice.contextOffForSite.label == "context off for this site")
    #expect(ContextNotice.siteNotChecked.label == "site not checked")
    #expect(ContextNotice.extensionNotConnected.label == "extension not connected")
    #expect(ContextNotice.noCaptions.label == "no captions")
}

@Test func pdfPageChipLabels() {
    func page(_ l: String) -> RenderedPage { RenderedPage(printedLabel: l, pdfIndex: 0, image: ImageAttachment(png: Data(), pixelWidth: 1, pixelHeight: 1), text: "") }
    #expect(ContextItem(piece: .pdfPages([page("231")])).chipLabel == "p. 231")
    #expect(ContextItem(piece: .pdfPages([page("231"), page("232")])).chipLabel == "pp. 231–232")
    #expect(ContextItem(piece: .pdfPages([page("231"), page("233")])).chipLabel == "pp. 231, 233")
    #expect(ContextItem(piece: .pdfPages([page("iv"), page("v")])).chipLabel == "pp. iv, v")
    #expect(ContextItem(piece: .pdfPages([page("231"), page("232"), page("233")])).chipLabel == "pp. 231–233")
}

@Test func capturedContextHelpers() {
    let img = ImageAttachment(png: Data([1]), pixelWidth: 1, pixelHeight: 1)
    let window = ContextItem(piece: .windowImage(img))
    let text = ContextItem(piece: .selectedText("hi"))
    let ctx = CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow, items: [window, text], isComplete: true)
    #expect(ctx.tabId == nil)
    #expect(ctx.hasImage)
    #expect(!ctx.hasExtractedMath)

    let removed = ctx.removingItem(window.id)
    #expect(removed.items == [text])
    #expect(!removed.hasImage)

    func only(_ piece: ContextPiece) -> CapturedContext {
        CapturedContext(front: nil, privacy: .allowed, kind: .mathPage, items: [ContextItem(piece: piece)], isComplete: false, tabId: 7)
    }
    #expect(only(.regionImage(img)).hasImage)
    #expect(only(.pdfPages([])).hasImage)
    #expect(!only(.math([])).hasExtractedMath)
    #expect(only(.math([MathSnippet(format: .latex, source: "x")])).hasExtractedMath)
    #expect(only(.math([])).tabId == 7)
}

@Test func frontAppInfoKeepsWindowFrame() {
    let f = FrontAppInfo(bundleID: "a", appName: "A", pid: 1, windowTitle: nil, windowFrame: CGRect(x: 1, y: 2, width: 3, height: 4))
    #expect(f.windowFrame?.width == 3)
}

@Test func knownBrowsers() {
    #expect(KnownBrowsers.isBrowser("company.thebrowser.dia"))
    #expect(!KnownBrowsers.isBrowser("com.apple.Notes"))
    #expect(KnownBrowsers.bundleIDs == ["company.thebrowser.dia", "com.google.Chrome", "company.thebrowser.Browser",
                                        "com.brave.Browser", "com.microsoft.edgemac", "com.apple.Safari", "org.mozilla.firefox"])
}
