import CompanionCore
import Foundation
import Observation

/// State of the bubble. WS7 mutates it through the public setters; user intents leave through `actions`.
/// The view model never echoes model, hint, new-chat or close state: the coordinator answers with
/// `setModelName`, `setHintMode`, `resetThread` and `BubbleController.hide()`.
@MainActor @Observable public final class BubbleViewModel {
    public init() {}

    @ObservationIgnored public weak var actions: (any BubbleActions)?
    public var inputText = ""
    public private(set) var context: CapturedContext?
    public private(set) var thread: [ThreadMessage] = []
    public private(set) var steps: [StepItem] = []
    public private(set) var pageThumbnails: [RenderedPage] = []
    public private(set) var documentChoice: DocumentChoice?
    public private(set) var modelName = ""
    public private(set) var hintMode = false
    public private(set) var isBusy = false
    public private(set) var error: BubbleErrorBanner?

    public func setContext(_ context: CapturedContext?) { self.context = context }
    public func setModelName(_ name: String) { modelName = name }
    public func setHintMode(_ on: Bool) { hintMode = on }
    public func resetThread(_ messages: [ThreadMessage]) { thread = messages }

    @discardableResult public func appendUserMessage(_ text: String) -> UUID {
        let message = ThreadMessage(role: .user, markdown: text)
        thread.append(message)
        return message.id
    }

    public func beginAssistantMessage() -> UUID {
        let message = ThreadMessage(role: .assistant, markdown: "", isStreaming: true)
        thread.append(message)
        return message.id
    }

    /// Appends only to the message with that id, and only while it is streaming.
    public func appendDelta(_ text: String, to id: UUID) {
        guard let index = thread.lastIndex(where: { $0.id == id }), thread[index].isStreaming else { return }
        thread[index].markdown += text
    }

    public func finishAssistantMessage(_ id: UUID) {
        guard let index = thread.lastIndex(where: { $0.id == id }) else { return }
        thread[index].isStreaming = false
    }

    public func setSteps(_ steps: [StepItem]) { self.steps = steps }
    public func setPageThumbnails(_ pages: [RenderedPage]) { pageThumbnails = pages }
    public func setDocumentChoice(_ choice: DocumentChoice?) { documentChoice = choice }
    public func showError(_ banner: BubbleErrorBanner?) { error = banner }
    public func setBusy(_ busy: Bool) { isBusy = busy }

    // MARK: Intents (internal: called by the bubble's own views)

    var inputPlaceholder: String { thread.isEmpty ? "Ask about this…" : "Follow up…" }

    func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions?.bubbleDidSubmit(trimmed)
        inputText = ""
    }

    func removeContextItem(_ id: UUID) {
        guard let context, let item = context.items.first(where: { $0.id == id }), item.isRemovable else { return }
        self.context = context.removingItem(id)
        actions?.bubbleDidRemoveContextItem(id)
    }

    func cycleModel() { actions?.bubbleDidRequestModelCycle() }
    func toggleHint() { actions?.bubbleDidToggleHint() }
    func newChat() { actions?.bubbleDidRequestNewChat() }
    func close() { actions?.bubbleDidClose() }
    func openSettings() { actions?.bubbleDidRequestSettings() }
    func switchModelAfterError() { actions?.bubbleDidRequestModelSwitchAfterError() }
    func selectDocument(_ file: DriveFileRef) { actions?.bubbleDidSelectDocument(file) }

    /// False only for `.insertNewline`, which the caller inserts itself.
    @discardableResult func handle(_ command: BubbleKeyCommand) -> Bool {
        switch command {
        case .submit: submit()
        case .insertNewline: return false
        case .close: close()
        case .cycleModel: cycleModel()
        case .toggleHint: toggleHint()
        case .newChat: newChat()
        }
        return true
    }
}
