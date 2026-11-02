import CompanionCore
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct ChunkAssemblerTests {
    static let pdf = Data((0..<2_621_440).map { UInt8(truncatingIfNeeded: $0 &* 31) })   // 2.5 MiB
    static var slices: [Data] { stride(from: 0, to: pdf.count, by: 1_048_576).map { pdf[$0..<min($0 + 1_048_576, pdf.count)] } }  // 3 slices
    func h(_ seq: Int, last: Bool = false, id: String = "r-7") -> BinaryFrameHeader { BinaryFrameHeader(id: id, seq: seq, last: last) }

    @Test func reassemblesInOrder() throws {
        var a = ChunkAssembler(requestID: "r-7"); let s = Self.slices
        try a.add(h(0), s[0]); try a.add(h(1), s[1]); try a.add(h(2, last: true), s[2])
        #expect(try a.assemble() == Self.pdf)
    }
    @Test func reordersOutOfOrderFrames() throws {
        var a = ChunkAssembler(requestID: "r-7"); let s = Self.slices
        try a.add(h(2, last: true), s[2]); try a.add(h(0), s[0]); try a.add(h(1), s[1])
        #expect(try a.assemble() == Self.pdf)
    }
    @Test func rejectsDuplicateSeq() async throws {
        var a = ChunkAssembler(requestID: "r-7")
        try a.add(h(0), Data([1]))
        do { try a.add(h(0), Data([1])); Issue.record("expected throw") } catch { #expect((error as? BridgeError)?.code == .internal) }
    }
    @Test func rejectsGap() async throws {
        var a = ChunkAssembler(requestID: "r-7")
        try a.add(h(0), Data([1])); try a.add(h(2, last: true), Data([3]))
        let done = a
        await expectBridgeError(.internal) { _ = try done.assemble() }
    }
    @Test func rejectsMissingLastFrame() async throws {
        var a = ChunkAssembler(requestID: "r-7")
        try a.add(h(0), Data([1])); try a.add(h(1), Data([2]))
        let done = a
        await expectBridgeError(.internal) { _ = try done.assemble() }
    }
    @Test func rejectsFrameAfterLast() throws {
        var a = ChunkAssembler(requestID: "r-7")
        try a.add(h(0, last: true), Data([1]))
        do { try a.add(h(1), Data([2])); Issue.record("expected throw") } catch { #expect((error as? BridgeError)?.code == .internal) }
        do { try a.add(h(1, last: true), Data([2])); Issue.record("expected throw") } catch { #expect((error as? BridgeError)?.code == .internal) }
    }
    @Test func rejectsLastBelowHigherSeq() throws {
        var a = ChunkAssembler(requestID: "r-7")
        try a.add(h(3), Data([1]))
        do { try a.add(h(1, last: true), Data([2])); Issue.record("expected throw") } catch { #expect((error as? BridgeError)?.code == .internal) }
    }
    @Test func rejectsForeignIDAndOversizedPayload() throws {
        var a = ChunkAssembler(requestID: "r-7")
        do { try a.add(h(0, id: "r-8"), Data([1])); Issue.record("expected throw") } catch { #expect((error as? BridgeError)?.code == .internal) }
        do { try a.add(h(0), Data(count: BridgeConstants.maxChunkBytes + 1)); Issue.record("expected throw") } catch { #expect((error as? BridgeError)?.code == .internal) }
    }
    @Test func noFramesAssemblesToEmpty() throws { #expect(try ChunkAssembler(requestID: "r-7").assemble().isEmpty) }
}
