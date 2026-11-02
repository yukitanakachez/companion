import CompanionCore

enum TranscriptWindow {
    /// Segments overlapping [max(0, playhead − lookback), playhead]: start <= to && start + duration > from.
    static func slice(segments: [TranscriptSegment], playhead: Double,
                      lookback: Double = CaptureConstants.transcriptLookback)
        -> (segments: [TranscriptSegment], from: Double, to: Double) {
        let from = max(0, playhead - lookback)
        let inWindow = segments.filter { $0.start <= playhead && $0.start + $0.duration > from }
        return (inWindow, from, playhead)
    }
}
