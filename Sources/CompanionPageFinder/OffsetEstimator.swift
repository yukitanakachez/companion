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
        // One vote is enough only when no sample disagrees by having no number: a lone stray number proves nothing.
        let floor = numberBearing == samples.count ? 1 : 2
        guard let winner, votes[winner]! >= max(floor, min(3, (numberBearing + 1) / 2)) else { return nil }
        return winner
    }

    /// Tries target − offset, then +1, −1, +2, −2 … ±10, skipping indices outside 0..<pageCount;
    /// returns the first index whose numbers contain target, unless that page also prints the number the offset
    /// expects there (then the target is its chapter number, not its page). Failing that, an unnumbered page whose
    /// two neighbours print target − 1 and target + 1 is the target: chapter openers often omit the number.
    static func locate(_ target: Int, offset: Int, pageCount: Int, numbersAt: (Int) -> [Int]) -> Int? {
        let center = target - offset
        var candidates = [center]
        for distance in 1...window { candidates += [center + distance, center - distance] }
        let inRange = candidates.filter { (0..<pageCount).contains($0) }
        let direct = inRange.first { index in
            let numbers = numbersAt(index)
            return numbers.contains(target) && (index == center || !numbers.contains(index + offset))
        }
        return direct ?? inRange.first { index in
            guard index > 0, index < pageCount - 1, numbersAt(index).isEmpty else { return false }
            return numbersAt(index - 1).contains(target - 1) && numbersAt(index + 1).contains(target + 1)
        }
    }
}
