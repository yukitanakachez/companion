import CoreGraphics
import Foundation

public enum ContextKind: String, Codable, Sendable, CaseIterable {
    case youtube, mathPage, webPage, pdfPages, genericWindow, region
}

public struct ImageAttachment: Codable, Sendable, Equatable {
    public var png: Data
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(png: Data, pixelWidth: Int, pixelHeight: Int) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var duration: Double
    public var text: String

    public init(start: Double, duration: Double, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }
}

public enum TranscriptStatus: String, Codable, Sendable, Equatable {
    case loading, available, unavailable
}

public struct YouTubeContext: Codable, Sendable, Equatable {
    public var videoId: String
    public var title: String
    public var channel: String?
    public var chapter: String?
    public var playheadSeconds: Double
    public var durationSeconds: Double?
    public var transcriptStatus: TranscriptStatus
    /// Empty unless `transcriptStatus` is `.available`.
    public var transcript: [TranscriptSegment]

    public init(videoId: String, title: String, channel: String?, chapter: String?,
                playheadSeconds: Double, durationSeconds: Double?,
                transcriptStatus: TranscriptStatus, transcript: [TranscriptSegment]) {
        self.videoId = videoId
        self.title = title
        self.channel = channel
        self.chapter = chapter
        self.playheadSeconds = playheadSeconds
        self.durationSeconds = durationSeconds
        self.transcriptStatus = transcriptStatus
        self.transcript = transcript
    }
}

public struct MathSnippet: Codable, Sendable, Equatable {
    public enum Format: String, Codable, Sendable { case latex, mathml }
    public var format: Format
    public var source: String

    public init(format: Format, source: String) {
        self.format = format
        self.source = source
    }
}

public struct WebPageContext: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var visibleText: String
    public var math: [MathSnippet]

    public init(url: String, title: String, visibleText: String, math: [MathSnippet]) {
        self.url = url
        self.title = title
        self.visibleText = visibleText
        self.math = math
    }
}

public struct DriveFileRef: Codable, Hashable, Sendable {
    public var fileId: String
    public var title: String
    public var mimeType: String?

    public init(fileId: String, title: String, mimeType: String?) {
        self.fileId = fileId
        self.title = title
        self.mimeType = mimeType
    }
}

public struct ClassroomContext: Codable, Sendable, Equatable {
    public var assignmentTitle: String?
    public var attachments: [DriveFileRef]

    public init(assignmentTitle: String?, attachments: [DriveFileRef]) {
        self.assignmentTitle = assignmentTitle
        self.attachments = attachments
    }
}

public struct DriveViewerContext: Codable, Sendable, Equatable {
    public var file: DriveFileRef

    public init(file: DriveFileRef) {
        self.file = file
    }
}

public struct TabContext: Codable, Sendable, Equatable {
    public var tabId: Int
    public var url: String
    public var title: String
    public var capturedAtMs: Double
    public var blocked: Bool
    public var page: WebPageContext?
    public var youtube: YouTubeContext?
    public var classroom: ClassroomContext?
    public var drive: DriveViewerContext?

    public init(tabId: Int, url: String, title: String, capturedAtMs: Double, blocked: Bool,
                page: WebPageContext?, youtube: YouTubeContext?,
                classroom: ClassroomContext?, drive: DriveViewerContext?) {
        self.tabId = tabId
        self.url = url
        self.title = title
        self.capturedAtMs = capturedAtMs
        self.blocked = blocked
        self.page = page
        self.youtube = youtube
        self.classroom = classroom
        self.drive = drive
    }
}

public struct FrontAppInfo: Sendable, Equatable {
    public var bundleID: String
    public var appName: String
    public var pid: Int32
    public var windowTitle: String?
    /// AppKit global coordinates.
    public var windowFrame: CGRect?

    public init(bundleID: String, appName: String, pid: Int32, windowTitle: String?, windowFrame: CGRect?) {
        self.bundleID = bundleID
        self.appName = appName
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
    }
}

public struct RenderedPage: Sendable, Equatable {
    public var printedLabel: String
    public var pdfIndex: Int
    public var image: ImageAttachment
    public var text: String

    public init(printedLabel: String, pdfIndex: Int, image: ImageAttachment, text: String) {
        self.printedLabel = printedLabel
        self.pdfIndex = pdfIndex
        self.image = image
        self.text = text
    }
}

public enum ContextNotice: String, CaseIterable, Sendable, Equatable {
    case contextOffForApp, contextOffForSite, siteNotChecked, extensionNotConnected, noCaptions

    public var label: String {
        switch self {
        case .contextOffForApp: "context off for this app"
        case .contextOffForSite: "context off for this site"
        case .siteNotChecked: "site not checked"
        case .extensionNotConnected: "extension not connected"
        case .noCaptions: "no captions"
        }
    }
}

public enum ContextPiece: Sendable, Equatable {
    case windowImage(ImageAttachment)
    case regionImage(ImageAttachment)
    case youtubeVideo(YouTubeContext)
    case transcriptWindow(segments: [TranscriptSegment], from: Double, to: Double)
    case webPage(WebPageContext)
    case math([MathSnippet])
    case pdfPages([RenderedPage])
    case selectedText(String)
    case focusedText(String)
    case notice(ContextNotice)
}

public struct ContextItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var piece: ContextPiece

    public init(id: UUID = UUID(), piece: ContextPiece) {
        self.id = id
        self.piece = piece
    }

    public var chipLabel: String {
        switch piece {
        case .windowImage: "window"
        case .regionImage: "region"
        case .youtubeVideo(let video): Self.videoLabel(video)
        case .transcriptWindow(_, let from, let to): "transcript \(formatTimestamp(from))–\(formatTimestamp(to))"
        case .webPage: "page text"
        case .math(let snippets): "math ×\(snippets.count)"
        case .pdfPages(let pages): Self.pagesLabel(pages.map(\.printedLabel))
        case .selectedText: "selection"
        case .focusedText: "screen text"
        case .notice(let notice): notice.label
        }
    }

    /// False only for `.notice`.
    public var isRemovable: Bool {
        if case .notice = piece { return false }
        return true
    }

    private static func videoLabel(_ video: YouTubeContext) -> String {
        let time = "▶ \(formatTimestamp(video.playheadSeconds))"
        guard let chapter = video.chapter else { return time }
        return "\(time) · \(chapter.prefix(24))"
    }

    private static func pagesLabel(_ labels: [String]) -> String {
        if labels.count == 1 { return "p. \(labels[0])" }
        let numbers = labels.compactMap { Int($0) }
        let isConsecutive = numbers.count == labels.count && numbers.count > 1
            && zip(numbers, numbers.dropFirst()).allSatisfy { $0 + 1 == $1 }
        if isConsecutive { return "pp. \(labels[0])–\(labels[labels.count - 1])" }
        return "pp. " + labels.joined(separator: ", ")
    }
}

public enum PrivacyDecision: Sendable, Equatable {
    case allowed
    case blocked(reason: String)
    case siteUnchecked
}

public struct CapturedContext: Sendable, Equatable {
    public var front: FrontAppInfo?
    public var privacy: PrivacyDecision
    public var kind: ContextKind
    public var items: [ContextItem]
    public var isComplete: Bool
    /// Browser tab the context came from (nil when not a browser / unknown).
    public var tabId: Int?

    public init(front: FrontAppInfo?, privacy: PrivacyDecision, kind: ContextKind,
                items: [ContextItem], isComplete: Bool, tabId: Int? = nil) {
        self.front = front
        self.privacy = privacy
        self.kind = kind
        self.items = items
        self.isComplete = isComplete
        self.tabId = tabId
    }

    /// True when a `windowImage`, `regionImage` or `pdfPages` item is present.
    public var hasImage: Bool {
        items.contains { item in
            switch item.piece {
            case .windowImage, .regionImage, .pdfPages: true
            default: false
            }
        }
    }

    /// True when a non-empty `.math` item is present.
    public var hasExtractedMath: Bool {
        items.contains { item in
            if case .math(let snippets) = item.piece { return !snippets.isEmpty }
            return false
        }
    }

    public func removingItem(_ id: UUID) -> CapturedContext {
        var copy = self
        copy.items.removeAll { $0.id == id }
        return copy
    }
}

public enum KnownBrowsers {
    /// Chromium-based browsers, which can run the Companion Bridge extension.
    public static let chromiumBundleIDs: Set<String> = [
        "company.thebrowser.dia",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]
    public static func usesExtension(_ bundleID: String) -> Bool { chromiumBundleIDs.contains(bundleID) }
    public static let bundleIDs: Set<String> = [
        "company.thebrowser.dia",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.apple.Safari",
        "org.mozilla.firefox",
    ]

    public static func isBrowser(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }
}

/// Formats seconds as `m:ss`, or `h:mm:ss` from one hour up. Negative and non-finite values are `0:00`.
public func formatTimestamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(min(seconds, 1e12))
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    let ss = String(format: "%02d", s)
    if h > 0 { return "\(h):\(String(format: "%02d", m)):\(ss)" }
    return "\(m):\(ss)"
}
