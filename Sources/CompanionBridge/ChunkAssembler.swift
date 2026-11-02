import CompanionCore
import Foundation

/// Collects the binary frames of one request. Frames may arrive in any order; anything that could
/// produce a truncated or corrupted file throws `BridgeError(.internal)`.
struct ChunkAssembler: Sendable {
    private let requestID: String
    private let maxChunkBytes: Int
    private var chunks: [Int: Data] = [:]
    private var lastSeq: Int?

    init(requestID: String, maxChunkBytes: Int = BridgeConstants.maxChunkBytes) {
        self.requestID = requestID
        self.maxChunkBytes = maxChunkBytes
    }

    mutating func add(_ header: BinaryFrameHeader, _ payload: Data) throws {
        guard header.id == requestID else { throw violation("Chunk for \(header.id) sent to \(requestID)") }
        guard header.seq >= 0 else { throw violation("Negative chunk seq \(header.seq)") }
        guard chunks[header.seq] == nil else { throw violation("Duplicate chunk seq \(header.seq)") }
        guard payload.count <= maxChunkBytes else { throw violation("Chunk of \(payload.count) bytes exceeds \(maxChunkBytes)") }
        if let lastSeq, header.last || header.seq > lastSeq {
            throw violation("Chunk seq \(header.seq) conflicts with last seq \(lastSeq)")
        }
        if header.last, let highest = chunks.keys.max(), highest > header.seq {
            throw violation("Last chunk seq \(header.seq) is below seq \(highest)")
        }
        chunks[header.seq] = payload
        if header.last { lastSeq = header.seq }
    }

    /// Empty when no frames were added; otherwise requires a last frame and exactly the seqs `0...last`.
    func assemble() throws -> Data {
        if chunks.isEmpty { return Data() }
        guard let lastSeq else { throw violation("Transfer ended without a last chunk") }
        guard chunks.count - 1 == lastSeq else {
            throw violation("Transfer has \(chunks.count) chunks, but its last seq is \(lastSeq)")
        }
        var output = Data(capacity: chunks.values.reduce(0) { $0 + $1.count })
        for seq in 0...lastSeq {
            guard let chunk = chunks[seq] else { throw violation("Missing chunk seq \(seq)") }
            output.append(chunk)
        }
        return output
    }

    private func violation(_ message: String) -> BridgeError {
        BridgeError(code: .internal, message: message)
    }
}
