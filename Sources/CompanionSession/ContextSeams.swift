import CompanionCapture
import CompanionCore
import CompanionUI
import CoreGraphics

protocol ContextGathering: Sendable {
    func gather(_ request: GatherRequest) async -> AsyncStream<CapturedContext>
}

@MainActor protocol RegionSelecting {
    func select() async -> RegionSelection?
}

@MainActor protocol GlowFlashing {
    func flash(_ rect: CGRect)
}

extension ContextGatherer: ContextGathering {}

struct LiveRegionSelector: RegionSelecting {
    func select() async -> RegionSelection? { await RegionSelector.select() }
}

struct LiveCaptureGlow: GlowFlashing {
    func flash(_ rect: CGRect) { CaptureGlow.flash(rect) }
}
