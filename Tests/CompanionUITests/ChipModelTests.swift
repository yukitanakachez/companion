import CompanionCore
import CompanionTestSupport
import Testing
@testable import CompanionUI

struct ChipModelTests {
    @Test func chipsFromContext() {
        let png = Fixtures.samplePNG()
        let ctx = CapturedContext(front: nil, privacy: .allowed, kind: .youtube, items: [
            ContextItem(piece: .windowImage(png)), ContextItem(piece: .youtubeVideo(youtubeSample)),
            ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761)), ContextItem(piece: .notice(.extensionNotConnected))],
            isComplete: true)
        let chips = ChipModel.chips(from: ctx)
        #expect(chips.map(\.label) == ["window", "▶ 12:41 · Finding the roots", "transcript 9:41–12:41", "extension not connected"])
        #expect(chips.map(\.isRemovable) == [true, true, true, false])
        #expect(chips[0].thumbnailPNG == png.png && chips[1].thumbnailPNG == nil)
        #expect(ChipModel.chips(from: nil).isEmpty)
    }
}
