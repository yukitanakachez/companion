import AppKit
import CompanionCore

@MainActor protocol BubblePresenting: AnyObject {
    var isVisible: Bool { get }
    func show(cursor: NSPoint, avoiding: CGRect?)
    func focusInput()
    func hide()
}

protocol ProviderResolving: Sendable {
    func provider(for model: ModelRef) throws -> any LLMProvider
}
