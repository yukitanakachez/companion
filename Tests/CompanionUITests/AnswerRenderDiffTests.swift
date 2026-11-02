import Foundation
import Testing
@testable import CompanionUI

struct AnswerRenderDiffTests {
    let u = ThreadMessage(role: .user, markdown: "q"), a = ThreadMessage(role: .assistant, markdown: "Hel", isStreaming: true)
    func with(_ m: ThreadMessage, _ change: (inout ThreadMessage) -> Void) -> ThreadMessage { var c = m; change(&c); return c }
    @Test func diffs() {
        #expect(AnswerRenderDiff.command(from: [u], to: [u]) == .none)
        #expect(AnswerRenderDiff.command(from: [u, a], to: [u, with(a) { $0.markdown = "Hello" }]) == .append(id: a.id, text: "lo"))
        for new in [[u, a, ThreadMessage(role: .user, markdown: "again")], [u, with(a) { $0.markdown = "Hex" }],
                    [u, with(a) { $0.isStreaming = false }], []] {
            #expect(AnswerRenderDiff.command(from: [u, a], to: new) == .render(new))
        }
    }
    @Test func scriptsUseJSONArguments() throws {
        let id = UUID(); let s = try #require(AnswerScript.script(for: .append(id: id, text: "\"q\" \\frac{1}{2} </script>")))
        #expect(s.hasPrefix("window.companion.appendDelta(\"\(id.uuidString)\",") && !s.contains("</script>"))
        #expect(AnswerScript.script(for: .none) == nil)
    }
}
