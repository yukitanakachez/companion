import CompanionCore
import Foundation

@MainActor public protocol BubbleActions: AnyObject {
    func bubbleDidSubmit(_ text: String)
    func bubbleDidRemoveContextItem(_ id: UUID)
    func bubbleDidRequestModelCycle()
    func bubbleDidToggleHint()
    func bubbleDidRequestNewChat()
    func bubbleDidClose()
    func bubbleDidRequestSettings()
    func bubbleDidSelectDocument(_ file: DriveFileRef)
    func bubbleDidRequestModelSwitchAfterError()
}

public struct ThreadMessage: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: LLMRole
    public var markdown: String
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: LLMRole, markdown: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.markdown = markdown
        self.isStreaming = isStreaming
    }
}

public enum StepState: Sendable, Equatable { case done, active, failed }

public struct StepItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var state: StepState

    public init(id: UUID = UUID(), text: String, state: StepState) {
        self.id = id
        self.text = text
        self.state = state
    }
}

public struct BubbleErrorBanner: Equatable, Sendable {
    public var message: String
    public var offerModelSwitch: Bool
    public var offerSettings: Bool

    public init(message: String, offerModelSwitch: Bool = false, offerSettings: Bool = false) {
        self.message = message
        self.offerModelSwitch = offerModelSwitch
        self.offerSettings = offerSettings
    }
}
