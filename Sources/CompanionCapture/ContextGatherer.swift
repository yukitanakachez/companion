import CompanionCore
import CoreGraphics
import Foundation

public actor ContextGatherer {
    private let accessibility: any AccessibilityReading
    private let windowCapturer: any WindowCapturing
    private let regionCapturer: any RegionCapturing
    private let browser: any BrowserContextProviding
    private let blocklist: @Sendable () -> BlocklistConfig
    private let browserWait: Duration
    private let imageTimeout: Duration

    public static func live(browser: any BrowserContextProviding,
                            blocklist: @escaping @Sendable () -> BlocklistConfig,
                            ownBundleID: String) -> ContextGatherer {
        ContextGatherer(accessibility: LiveAccessibilityReader(ownBundleID: ownBundleID),
                        windowCapturer: LiveWindowCapturer(),
                        regionCapturer: LiveRegionCapturer(ownBundleID: ownBundleID, blocklist: blocklist),
                        browser: browser, blocklist: blocklist)
    }

    init(accessibility: any AccessibilityReading, windowCapturer: any WindowCapturing,
         regionCapturer: any RegionCapturing, browser: any BrowserContextProviding,
         blocklist: @escaping @Sendable () -> BlocklistConfig,
         browserWait: Duration = BridgeConstants.hotPathTimeout,
         imageTimeout: Duration = CaptureConstants.imageTimeout) {
        self.accessibility = accessibility
        self.windowCapturer = windowCapturer
        self.regionCapturer = regionCapturer
        self.browser = browser
        self.blocklist = blocklist
        self.browserWait = browserWait
        self.imageTimeout = imageTimeout
    }

    /// First element within 50 ms (front app + privacy decision); emits again as each piece lands;
    /// the final element is complete. Finishes after the final element.
    /// Item ids are stable across the emissions of one gather (the same piece keeps its id), and
    /// `tabId` is set whenever browser tab context was used.
    public func gather(_ request: GatherRequest) -> AsyncStream<CapturedContext> {
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedContext.self)
        let task = Task { [accessibility, windowCapturer, regionCapturer, browser, blocklist, browserWait, imageTimeout] in
            await Self.run(request, accessibility: accessibility, windowCapturer: windowCapturer,
                           regionCapturer: regionCapturer, browser: browser, blocklist: blocklist,
                           browserWait: browserWait, imageTimeout: imageTimeout, output: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private enum Landing: Sendable {
        case image(ImageAttachment?)
        case text(selected: String?, focused: String?)
        case tab(TabContext?)
    }

    private nonisolated static func run(_ request: GatherRequest,
                                        accessibility ax: any AccessibilityReading,
                                        windowCapturer: any WindowCapturing,
                                        regionCapturer: any RegionCapturing,
                                        browser: any BrowserContextProviding,
                                        blocklist: @Sendable () -> BlocklistConfig,
                                        browserWait: Duration, imageTimeout: Duration,
                                        output: AsyncStream<CapturedContext>.Continuation) async {
        // 1. Front app and config.
        let front = await ax.frontApp()
        let config = blocklist()
        let isBrowser = front.map { KnownBrowsers.isBrowser($0.bundleID) } ?? false
        var snapshot = SummonSnapshot(front: front, privacy: .allowed, isBrowser: isBrowser, extensionConnected: false)

        func emit() { output.yield(ContextAssembler.assemble(snapshot)) }
        func emitBlockedAndComplete() {
            emit()
            snapshot.isComplete = true
            emit()
        }

        // 2. Bundle check: a blocked app gets nothing else called, not even its window title.
        snapshot.privacy = PrivacyGate.evaluate(front: front, isBrowser: isBrowser, tab: nil, browserURL: nil, config: config)
        if case .blocked = snapshot.privacy { return emitBlockedAndComplete() }

        // 3. Extension state. Safari and Firefox never consult the extension.
        let usesExtension = front.map { KnownBrowsers.usesExtension($0.bundleID) } ?? false
        if usesExtension {
            snapshot.extensionConnected = await browser.isConnected()
            snapshot.tab = await browser.cachedActiveTabContext()
        }

        // 4. Address bar.
        var url: URL?
        if isBrowser, snapshot.tab == nil, let front {
            url = await ax.browserURL(pid: front.pid)
        }

        // 5. First emission.
        snapshot.privacy = PrivacyGate.evaluate(front: front, isBrowser: isBrowser, tab: snapshot.tab, browserURL: url, config: config)
        if case .blocked = snapshot.privacy { return emitBlockedAndComplete() }
        emit()

        // 6. Window details.
        let focusedWindow = if let front { await ax.focusedWindow(pid: front.pid) } else { FocusedWindowInfo?.none }
        let focusedFrame = focusedWindow?.frame
        if let focusedWindow {
            snapshot.front?.windowTitle = focusedWindow.title
            snapshot.front?.windowFrame = focusedWindow.frame
        }

        // 7–8. Concurrent pieces. While the tab question is open, image and text are held back
        // (for at most `browserWait`), so a late "blocked" never follows an emitted capture.
        var awaitingTab = usesExtension && snapshot.extensionConnected && snapshot.tab == nil
        let isRegion: Bool = if case .region = request { true } else { false }
        await withTaskGroup(of: Landing.self) { group in
            switch request {
            case .frontWindow:
                if let pid = front?.pid {
                    group.addTask {
                        .image(await withTimeLimit(imageTimeout) {
                            try? await windowCapturer.captureFrontWindow(pid: pid, focusedFrame: focusedFrame)
                        })
                    }
                }
            case .region(let selection):
                group.addTask {
                    .image(await withTimeLimit(imageTimeout) { try? await regionCapturer.capture(selection) })
                }
            }
            if let pid = front?.pid {
                group.addTask { .text(selected: await ax.selectedText(pid: pid), focused: await ax.focusedText(pid: pid)) }
            }
            if awaitingTab {
                group.addTask {
                    .tab(await withTimeLimit(browserWait) { await browser.requestActiveTabContext(timeout: browserWait) })
                }
            }

            for await landing in group {
                switch landing {
                case .image(let image):
                    if isRegion { snapshot.regionImage = image } else { snapshot.windowImage = image }
                case .text(let selected, let focused):
                    snapshot.selectedText = selected
                    snapshot.focusedText = focused
                case .tab(let tab):
                    awaitingTab = false
                    snapshot.tab = tab
                    snapshot.privacy = PrivacyGate.evaluate(front: front, isBrowser: isBrowser, tab: tab, browserURL: url, config: config)
                    if case .blocked = snapshot.privacy {
                        group.cancelAll()
                        return
                    }
                }
                if !awaitingTab { emit() }
            }
        }

        // 9. Final emission. A late block is emitted once, as complete, with only its notice.
        snapshot.isComplete = true
        emit()
    }
}
