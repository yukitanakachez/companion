import CompanionCore
import Foundation

/// One UUID per item slot, created once per gather so chip ids stay stable across emissions.
struct ItemIDs: Sendable, Equatable {
    let image = UUID(), youtube = UUID(), transcript = UUID(), webPage = UUID()
    let math = UUID(), selection = UUID(), screenText = UUID()
    let notices: [ContextNotice: UUID]

    init() {
        notices = Dictionary(uniqueKeysWithValues: ContextNotice.allCases.map { ($0, UUID()) })
    }
}

struct SummonSnapshot: Sendable {
    var front: FrontAppInfo?
    var privacy: PrivacyDecision
    var isBrowser: Bool
    var extensionConnected: Bool
    var windowImage: ImageAttachment? = nil
    var regionImage: ImageAttachment? = nil
    var selectedText: String? = nil
    var focusedText: String? = nil
    var tab: TabContext? = nil
    var isComplete: Bool = false
    var itemIDs = ItemIDs()
}

enum ContextAssembler {
    static func assemble(_ snapshot: SummonSnapshot) -> CapturedContext {
        if case .blocked(let reason) = snapshot.privacy {
            return blocked(snapshot, reason: reason)
        }
        let ids = snapshot.itemIDs
        var items: [ContextItem] = []
        func add(_ id: UUID, _ piece: ContextPiece) { items.append(ContextItem(id: id, piece: piece)) }
        func addNotice(_ notice: ContextNotice) { add(ids.notices[notice] ?? UUID(), .notice(notice)) }

        if let region = snapshot.regionImage {
            add(ids.image, .regionImage(region))
        } else if let window = snapshot.windowImage {
            add(ids.image, .windowImage(window))
        }

        let youtube = snapshot.tab?.youtube
        if let youtube {
            add(ids.youtube, .youtubeVideo(youtube))
            if youtube.transcriptStatus == .available {
                let window = TranscriptWindow.slice(segments: youtube.transcript, playhead: youtube.playheadSeconds)
                if !window.segments.isEmpty {
                    add(ids.transcript, .transcriptWindow(segments: window.segments, from: window.from, to: window.to))
                }
            }
        }

        let page = snapshot.tab?.page
        if var page, !isBlank(page.visibleText) {
            page.visibleText = String(page.visibleText.prefix(CaptureConstants.pageTextCap))
            page.math = Array(page.math.prefix(CaptureConstants.mathCap))
            add(ids.webPage, .webPage(page))
        }
        let math = Array((page?.math ?? []).prefix(CaptureConstants.mathCap))
        if !math.isEmpty {
            add(ids.math, .math(math))
        }

        let selected = snapshot.selectedText.flatMap { isBlank($0) ? nil : $0 }
        if let selected {
            add(ids.selection, .selectedText(selected))
        }
        if let focused = snapshot.focusedText, !isBlank(focused), focused != selected {
            add(ids.screenText, .focusedText(String(focused.prefix(CaptureConstants.focusedTextCap))))
        }

        if snapshot.privacy == .siteUnchecked { addNotice(.siteNotChecked) }
        if snapshot.isBrowser, !snapshot.extensionConnected { addNotice(.extensionNotConnected) }
        if youtube?.transcriptStatus == .unavailable { addNotice(.noCaptions) }

        let kind: ContextKind =
            if snapshot.regionImage != nil { .region }
            else if youtube != nil { .youtube }
            else if !math.isEmpty { .mathPage }
            else if page != nil { .webPage }
            else { .genericWindow }

        return CapturedContext(front: snapshot.front, privacy: snapshot.privacy, kind: kind, items: items,
                               isComplete: snapshot.isComplete, tabId: snapshot.tab?.tabId)
    }

    /// A blocked context holds a single notice, and `front` keeps no window details.
    private static func blocked(_ snapshot: SummonSnapshot, reason: String) -> CapturedContext {
        let notice: ContextNotice = reason == PrivacyGate.siteBlockedReason ? .contextOffForSite : .contextOffForApp
        let front = snapshot.front.map {
            FrontAppInfo(bundleID: $0.bundleID, appName: $0.appName, pid: $0.pid, windowTitle: nil, windowFrame: nil)
        }
        let item = ContextItem(id: snapshot.itemIDs.notices[notice] ?? UUID(), piece: .notice(notice))
        return CapturedContext(front: front, privacy: snapshot.privacy, kind: .genericWindow, items: [item],
                               isComplete: snapshot.isComplete)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
