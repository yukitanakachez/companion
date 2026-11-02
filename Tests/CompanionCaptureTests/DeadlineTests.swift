import Testing
@testable import CompanionCapture

@Test func returnsFastValue() async { #expect(await withTimeLimit(.milliseconds(300)) { 5 } == 5) }
@Test func abandonsNonCooperativeOperation() async {
    let start = ContinuousClock.now
    let v: Int? = await withTimeLimit(.milliseconds(100)) { await nonCooperativeSleep(1); return 1 }
    #expect(v == nil && ContinuousClock.now - start < .milliseconds(300))
}
@Test func callerCancellationReturnsNil() async {
    let start = ContinuousClock.now
    let t = Task { () -> Int? in await withTimeLimit(.seconds(5)) { await nonCooperativeSleep(1); return 1 } }
    t.cancel()
    let v = await t.value
    #expect(v == nil && ContinuousClock.now - start < .milliseconds(300))
}
