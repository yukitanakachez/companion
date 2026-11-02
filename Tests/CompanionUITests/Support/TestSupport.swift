import AppKit
import CompanionCore
import Testing
@testable import CompanionUI

@MainActor final class RecordingBubbleActions: BubbleActions {
    enum Call: Equatable {
        case submit(String), removeItem(UUID), cycleModel, toggleHint, newChat, close, settings,
             selectDocument(DriveFileRef), switchModelAfterError
    }
    private(set) var calls: [Call] = []
    func bubbleDidSubmit(_ text: String) { calls.append(.submit(text)) }
    func bubbleDidRemoveContextItem(_ id: UUID) { calls.append(.removeItem(id)) }
    func bubbleDidRequestModelCycle() { calls.append(.cycleModel) }
    func bubbleDidToggleHint() { calls.append(.toggleHint) }
    func bubbleDidRequestNewChat() { calls.append(.newChat) }
    func bubbleDidClose() { calls.append(.close) }
    func bubbleDidRequestSettings() { calls.append(.settings) }
    func bubbleDidSelectDocument(_ file: DriveFileRef) { calls.append(.selectDocument(file)) }
    func bubbleDidRequestModelSwitchAfterError() { calls.append(.switchModelAfterError) }
}

/// Parent of every suite that creates an NSWindow or WKWebView, so they never interleave.
@MainActor @Suite(.serialized) enum WindowTests {}

@MainActor enum TestApp {
    private static var done = false
    static func ensure() {
        guard !done else { return }
        done = true
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }
}

func keyEvent(_ keyCode: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: keyCode)!
}

let youtubeSample = YouTubeContext(videoId: "abc", title: "Solving Quadratics by Factoring", channel: nil,
                                   chapter: "Finding the roots", playheadSeconds: 761, durationSeconds: 1450,
                                   transcriptStatus: .available, transcript: [])
