import CompanionCore
import Foundation

enum AnswerRenderCommand: Equatable {
    case none, render([ThreadMessage]), append(id: UUID, text: String)
}

enum AnswerRenderDiff {
    static func command(from old: [ThreadMessage], to new: [ThreadMessage]) -> AnswerRenderCommand {
        if old == new { return .none }
        guard old.count == new.count, let oldLast = old.last, let newLast = new.last,
              old.dropLast() == new.dropLast(),
              oldLast.id == newLast.id, oldLast.role == newLast.role,
              oldLast.isStreaming, newLast.isStreaming,
              newLast.markdown.hasPrefix(oldLast.markdown) else { return .render(new) }
        return .append(id: newLast.id, text: String(newLast.markdown.dropFirst(oldLast.markdown.count)))
    }
}

enum AnswerScript {
    private struct Message: Encodable {
        let id: String, role: String, markdown: String, isStreaming: Bool
    }

    /// Arguments are JSON-encoded, never interpolated: LaTeX backslashes and quotes must survive.
    static func script(for command: AnswerRenderCommand) -> String? {
        switch command {
        case .none:
            return nil
        case .render(let thread):
            let messages = thread.map { Message(id: $0.id.uuidString, role: $0.role.rawValue, markdown: $0.markdown, isStreaming: $0.isStreaming) }
            return "window.companion.render(\(json(messages)))"
        case .append(let id, let text):
            return "window.companion.appendDelta(\(json(id.uuidString)),\(json(text)))"
        }
    }

    private static func json(_ value: some Encodable) -> String {
        // Encoding plain strings and arrays of them cannot fail.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
