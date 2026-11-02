import Testing
import CompanionCore
@testable import CompanionCapture

@Test func fixtureWindowIncludesBoundaryOverlap() throws {              // 575.0 + 6.2 = 581.2 > 581
    let w = TranscriptWindow.slice(segments: try tabFixture("ext-tabContext-youtube.json").youtube!.transcript, playhead: 761)
    #expect(w.from == 581 && w.to == 761 && w.segments.count == 3)
}
@Test func segmentEndingExactlyAtWindowStartIsExcluded() {
    #expect(TranscriptWindow.slice(segments: [TranscriptSegment(start: 575, duration: 6, text: "a")], playhead: 761).segments.isEmpty)
}
@Test func startOfVideo() {
    let w = TranscriptWindow.slice(segments: [0, 30, 59.5, 60, 61].map { TranscriptSegment(start: $0, duration: 3, text: "t") }, playhead: 60)
    #expect(w.from == 0 && w.to == 60 && w.segments.map(\.start) == [0, 30, 59.5, 60])
}
@Test func emptyTranscript() {
    let w = TranscriptWindow.slice(segments: [], playhead: 761)
    #expect(w.segments.isEmpty && w.from == 581 && w.to == 761)
}
