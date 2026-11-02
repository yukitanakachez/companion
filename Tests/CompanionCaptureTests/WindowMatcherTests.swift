import Testing
import CoreGraphics
@testable import CompanionCapture

private let w1 = WindowCandidate(windowID: 1, pid: 42, layer: 0, frame: R(0, 25, 1200, 800))
private let w2 = WindowCandidate(windowID: 2, pid: 42, layer: 0, frame: R(300, 200, 900, 700))
private let other = WindowCandidate(windowID: 3, pid: 7, layer: 0, frame: R(0, 0, 3000, 2000))
private let menu = WindowCandidate(windowID: 4, pid: 42, layer: 25, frame: R(0, 0, 3000, 30))

@Test func picksBestOverlapWithFocusedFrame() { #expect(WindowMatcher.pick([w1, w2, other, menu], pid: 42, focusedFrame: w2.frame) == 2) }
@Test func fallsBackToLargest() {
    #expect(WindowMatcher.pick([w1, w2], pid: 42, focusedFrame: nil) == 1)
    #expect(WindowMatcher.pick([w1, w2], pid: 42, focusedFrame: R(5000, 5000, 10, 10)) == 1)     // no overlap
}
@Test func matcherIgnoresOtherPidsAndLayers() {
    #expect(WindowMatcher.pick([other, menu], pid: 42, focusedFrame: nil) == nil)
    #expect(WindowMatcher.pick([], pid: 42, focusedFrame: nil) == nil)
}
