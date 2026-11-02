/// Pure printed-number arithmetic, reused by the text-layer, text-recognition and viewer paths.
enum OffsetEstimator {
    static let window = 10

    /// Evenly spaced, includes first and last; every index when pageCount ≤ maxSamples.
    static func sampleIndices(pageCount: Int, maxSamples: Int) -> [Int] {
        guard pageCount > maxSamples else { return Array(0..<max(pageCount, 0)) }
        guard maxSamples > 1 else { return maxSamples == 1 ? [0] : [] }
        let last = pageCount - 1, steps = maxSamples - 1
        return (0...steps).map { ($0 * last + steps / 2) / steps }
    }

    /// offset = printed − pdfIndex. nil unless the winner has ≥ min(3, (n + 1) / 2) votes (n = samples with ≥ 1 number).
    /// Ties go to the offset whose first vote came from the lowest pdfIndex (the first section of a book whose
    /// numbering restarts).
    static func estimate(_ samples: [(pdfIndex: Int, numbers: [Int])]) -> Int? {
        var votes: [Int: Int] = [:]
        var firstSeen: [Int] = []
        var numberBearing = 0
        for sample in samples.sorted(by: { $0.pdfIndex < $1.pdfIndex }) where !sample.numbers.isEmpty {
            numberBearing += 1
            var counted = Set<Int>()
            for number in sample.numbers {
                let offset = number - sample.pdfIndex
                guard counted.insert(offset).inserted else { continue }
                if votes[offset] == nil { firstSeen.append(offset) }
                votes[offset, default: 0] += 1
            }
        }
        var winner: Int?
        for offset in firstSeen where votes[offset]! > (winner.flatMap { votes[$0] } ?? 0) {
            winner = offset
        }
        guard let winner, votes[winner]! >= min(3, (numberBearing + 1) / 2) else { return nil }
        return winner
    }

    /// Tries target − offset, then +1, −1, +2, −2 … ±10, skipping indices outside 0..<pageCount;
    /// returns the first index whose numbers contain target.
    static func locate(_ target: Int, offset: Int, pageCount: Int, numbersAt: (Int) -> [Int]) -> Int? {
        let center = target - offset
        var candidates = [center]
        for distance in 1...window { candidates += [center + distance, center - distance] }
        return candidates.first { (0..<pageCount).contains($0) && numbersAt($0).contains(target) }
    }
}
