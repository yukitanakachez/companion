import Testing
import CoreGraphics
@testable import CompanionCapture

private func px(_ sel: CGRect, _ display: CGRect, _ scale: CGFloat) -> CGRect {
    ScreenGeometry.displayPixelRect(selection: sel, displayFrameCG: display, primaryHeight: 982, scale: scale)
}

@Test func flipRoundTrip() {
    #expect(ScreenGeometry.flipped(R(100, 100, 800, 600), primaryHeight: 982) == R(100, 282, 800, 600))
    #expect(ScreenGeometry.flipped(ScreenGeometry.flipped(R(100, 100, 800, 600), primaryHeight: 982), primaryHeight: 982) == R(100, 100, 800, 600))
}
@Test func flipForDisplayAbovePrimary() { #expect(ScreenGeometry.flipped(R(200, 1100, 400, 300), primaryHeight: 982) == R(200, -418, 400, 300)) }
@Test func fittedSizes() {
    #expect(ScreenGeometry.fittedPixelSize(width: 3024, height: 1964) == (1500, 974))
    #expect(ScreenGeometry.fittedPixelSize(width: 1964, height: 3024) == (974, 1500))
    #expect(ScreenGeometry.fittedPixelSize(width: 800, height: 600) == (800, 600))       // never upscaled
    #expect(ScreenGeometry.fittedPixelSize(width: 4000, height: 1) == (1500, 1))         // min 1 px
}
@Test func pixelRectOnRetinaPrimary()        { #expect(px(R(100, 682, 200, 100), R(0, 0, 1512, 982), 2) == R(200, 400, 400, 200)) }
@Test func pixelRectOnDisplayLeftOfPrimary() { #expect(px(R(-1820, 782, 300, 100), R(-1920, 0, 1920, 1080), 1) == R(100, 100, 300, 100)) }
@Test func pixelRectOnDisplayAbovePrimary()  { #expect(px(R(10, 2322, 100, 50), R(0, -1440, 2560, 1440), 1) == R(10, 50, 100, 50)) }
@Test func pixelRectClampsToDisplay()        { #expect(px(R(1400, 682, 300, 100), R(0, 0, 1512, 982), 2) == R(2800, 400, 224, 200)) }
