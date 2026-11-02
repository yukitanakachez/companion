import CoreGraphics
import Testing
@testable import CompanionUI

let main = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 60, width: 1512, height: 889))
let left = (frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
let size = CGSize(width: 380, height: 200)
func place(_ x: CGFloat, _ y: CGFloat, _ screens: [ScreenGeometry] = [main], avoid: CGRect? = nil, size: CGSize = size) -> CGRect {
    BubblePlacement.frame(cursor: CGPoint(x: x, y: y), size: size, screens: screens, avoid: avoid)
}
func resize(_ f: CGRect, _ h: CGFloat, top: Bool) -> CGRect { BubblePlacement.resized(f, toHeight: h, anchorTop: top, visibleFrame: main.visibleFrame) }
func r(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat = 200) -> CGRect { CGRect(x: x, y: y, width: 380, height: h) }

@Test func rightBelowByDefault() { #expect(place(600, 600) == r(616, 384)) }
@Test func secondaryDisplayAtNegativeX() { let f = place(-1000, 600, [main, left]); #expect(f == r(-984, 384) && left.visibleFrame.contains(f)) }
@Test func cursorOnTopEdgeOfSecondaryDisplay() { #expect(place(-1000, 1080, [main, left]) == r(-984, 855)) }   // mouseLocation.y can equal maxY
@Test func flipsNearRightAndBottomEdges() {
    #expect(place(1400, 600) == r(1004, 384)); #expect(place(200, 150) == r(216, 166)); #expect(place(1400, 150) == r(1004, 166))
}
@Test func avoidRectForcesAlternative() { #expect(place(600, 600, avoid: CGRect(x: 610, y: 300, width: 500, height: 290)) == r(204, 384)) }
@Test func unavoidableAvoidFallsBackToFirstInside() {
    #expect(place(600, 600, avoid: main.visibleFrame) == r(616, 384))
}
@Test func avoidAroundCursorMovesBesideIt() {   // region selection under the cursor: cursor candidates all overlap → right-of the selection
    #expect(place(600, 600, avoid: CGRect(x: 450, y: 500, width: 300, height: 200)) == r(762, 384))
}
@Test func fullScreenSpaceStaysInside() {
    let fs = (frame: main.frame, visibleFrame: main.frame); let f = place(1500, 10, [fs])
    #expect(f == r(1104, 26) && fs.visibleFrame.contains(f))
}
@Test func oversizeAndOffscreenAreClamped() {
    #expect(place(600, 600, size: CGSize(width: 380, height: 2000)) == r(616, 60, 889))
    #expect(main.visibleFrame.contains(place(5000, 5000, [main, left])))   // cursor off every screen → first screen
}
@Test func resizedKeepsTheCursorSideEdgeAndStaysInside() {
    #expect(resize(r(616, 384), 300, top: true) == r(616, 284, 300)); #expect(resize(r(616, 100, 72), 520, top: true) == r(616, 60, 520))
    #expect(resize(r(216, 166), 400, top: false) == r(216, 166, 400)); #expect(resize(r(216, 700), 2000, top: false) == r(216, 60, 889))
}
@Test func clampedHeight() { #expect([10, 300, 5000].map(BubbleMetrics.clampedHeight) == [72, 300, 520]) }
