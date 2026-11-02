import CompanionCore
import Foundation

public struct PromptBuilder: Sendable {
    static let baseInstructions = """
    You are Companion, a study helper the student summons with a hotkey while looking at something on their Mac. Each question arrives with the context the app captured at that moment: screenshots, page text and math, a video's title and recent transcript, or textbook pages.

    - Answer exactly what the student asked. If they ask for a hint, give a hint. If they ask you to check their work, check it and point to the first mistake. If they ask you to solve, solve it.
    - Be concise: lead with the answer, then only the steps that matter.
    - Format in Markdown. Write all math in LaTeX, with $...$ for inline math and $$...$$ for display math.
    - Use only the supplied context and the conversation so far for what the student is looking at. If that is not enough to answer, say exactly what is missing instead of guessing.
    """
    static let hintModeInstructions = """
    Hint mode is on. Teach Socratically:
    - Give only the next hint: one step or one guiding question that moves the student forward.
    - Never give the full solution or the final answer unless the student explicitly asks for it.
    - If the student shares their work, say whether it is right so far, then hint at the next step.
    """
    static let readingLineInstruction = "Begin with one line `Reading: <the problem in LaTeX>` when you are solving or checking a problem you read from the image."
    static let omittedImagePlaceholder = "[image from an earlier turn omitted]"

    public init() {}

    /// Returns the system prompt and `history + [new user message]`, normalized: older turns lose their
    /// images, empty text and empty messages are dropped, and consecutive same-role turns are merged.
    public func build(question: String, context: CapturedContext?, history: [LLMMessage],
                      hintMode: Bool) -> (system: String, messages: [LLMMessage]) {
        let turn = newTurn(question: question, context: context)
        return (systemPrompt(context: context, hintMode: hintMode), normalize(history.map(omittingImages) + [turn]))
    }

    private func systemPrompt(context: CapturedContext?, hintMode: Bool) -> String {
        var parts = [Self.baseInstructions]
        if hintMode { parts.append(Self.hintModeInstructions) }
        if let context, !context.hasExtractedMath, context.items.contains(where: Self.isScreenshot) {
            parts.append(Self.readingLineInstruction)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func isScreenshot(_ item: ContextItem) -> Bool {
        switch item.piece {
        case .windowImage, .regionImage: true
        default: false
        }
    }

    private func newTurn(question: String, context: CapturedContext?) -> LLMMessage {
        var images: [ImageAttachment] = []
        var sections: [String] = []
        if let context {
            // A blocked app's name and window title must not reach the model (spec §2 anti-goals).
            if let front = context.front, !Self.isBlocked(context.privacy) { sections.append(Self.section(for: front)) }
            for item in context.items { sections += Self.sections(for: item.piece, images: &images) }
        }
        let text = sections.isEmpty ? question : "<context>\n\(sections.joined(separator: "\n\n"))\n</context>\n\n\(question)"
        return LLMMessage(role: .user, content: images.map(LLMContent.image) + [.text(text)])
    }

    private static func isBlocked(_ privacy: PrivacyDecision) -> Bool {
        if case .blocked = privacy { return true }
        return false
    }

    private static func section(for front: FrontAppInfo) -> String {
        var lines = ["App: \(front.appName)"]
        if let title = front.windowTitle, !title.isEmpty { lines.append("Window: \(title)") }
        return lines.joined(separator: "\n")
    }

    /// Appends the piece's images to `images`, which numbers them 1…N in placement order.
    private static func sections(for piece: ContextPiece, images: inout [ImageAttachment]) -> [String] {
        switch piece {
        case .windowImage(let image):
            images.append(image)
            return ["Image \(images.count): screenshot of the front window"]
        case .regionImage(let image):
            images.append(image)
            return ["Image \(images.count): screenshot of a selected screen region"]
        case .youtubeVideo(let video):
            var lines = ["YouTube video: \(video.title)"]
            if let channel = video.channel { lines.append("Channel: \(channel)") }
            if let chapter = video.chapter { lines.append("Chapter: \(chapter)") }
            let position = "Position: at \(formatTimestamp(video.playheadSeconds))"
            lines.append(video.durationSeconds.map { "\(position) of \(formatTimestamp($0))" } ?? position)
            return [lines.joined(separator: "\n")]
        case .transcriptWindow(let segments, let from, let to):
            let lines = segments.map { "[\(formatTimestamp($0.start))] \($0.text)" }
            return [(["Transcript from \(formatTimestamp(from)) to \(formatTimestamp(to)):"] + lines).joined(separator: "\n")]
        case .webPage(let page):
            return ["Web page: \(page.title)\nURL: \(page.url)\nVisible text:\n\(page.visibleText)"]
        case .math(let snippets):
            let lines = snippets.map { snippet in
                switch snippet.format {
                case .latex: "- LaTeX: \(snippet.source)"
                case .mathml: "- MathML: \(snippet.source)"
                }
            }
            return [(["Math on the page (exact source):"] + lines).joined(separator: "\n")]
        case .selectedText(let text):
            return ["Selected text:\n\(text)"]
        case .focusedText(let text):
            return ["Screen text:\n\(text)"]
        case .pdfPages(let pages):
            return pages.map { page in
                images.append(page.image)
                let header = "Book page \(page.printedLabel) (PDF page \(page.pdfIndex + 1)), image \(images.count):"
                return page.text.isEmpty ? header : "\(header)\n\(page.text)"
            }
        case .notice(let notice):
            return ["Note: \(notice.label)"]
        }
    }

    /// Replaces all images in a message with one placeholder at the first image's position.
    private func omittingImages(_ message: LLMMessage) -> LLMMessage {
        var copy = message
        var replaced = false
        copy.content = message.content.compactMap { block in
            guard case .image = block else { return block }
            defer { replaced = true }
            return replaced ? nil : .text(Self.omittedImagePlaceholder)
        }
        return copy
    }

    /// Anthropic returns a 400 on empty text blocks and on non-alternating roles,
    /// and a failed or cancelled turn can leave either behind.
    private func normalize(_ messages: [LLMMessage]) -> [LLMMessage] {
        var result: [LLMMessage] = []
        for message in messages {
            let content = message.content.filter { block in
                if case .text(let text) = block { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return true
            }
            if content.isEmpty { continue }
            if let last = result.indices.last, result[last].role == message.role {
                result[last].content += content
            } else {
                result.append(LLMMessage(role: message.role, content: content))
            }
        }
        return result
    }
}
