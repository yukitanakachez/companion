import AppKit
import CoreImage
import QuartzCore

/// Layer-backed so Core Animation runs the breathing on the render server: an always-on orb must cost ~0 CPU.
final class OrbView: NSView {
    private let onMouseUp: (_ dragged: Bool, _ center: CGPoint) -> Void
    private var downLocation: CGPoint?
    private var downCenter: CGPoint = .zero
    private var dragged = false

    init(frame: CGRect, onMouseUp: @escaping (_ dragged: Bool, _ center: CGPoint) -> Void) {
        self.onMouseUp = onMouseUp
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true   // the halo's blur
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayers() {
        guard let root = layer else { return }
        let side = OrbPlacement.diameter
        let bodyFrame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let aurora = Theme.auroraCG + [Theme.auroraCG[0]]
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let halo = CAGradientLayer()
        halo.type = .conic
        halo.frame = bodyFrame.insetBy(dx: -6, dy: -6)
        halo.colors = aurora
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 0.5)
        halo.cornerRadius = halo.frame.width / 2
        halo.opacity = 0.35
        halo.masksToBounds = true
        let blurred = CALayer()
        blurred.frame = bounds
        blurred.addSublayer(halo)
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]) {
            blurred.filters = [blur]
        }
        root.addSublayer(blurred)

        let body = CAGradientLayer()
        body.type = .radial
        body.frame = bodyFrame
        body.cornerRadius = side / 2
        body.masksToBounds = true
        body.colors = [CGColor(gray: 1, alpha: 0.85), Theme.cgColor(hex: 0x6E7BFF), Theme.cgColor(hex: 0x2A2F6B)]
        body.locations = [0, 0.45, 1]
        body.startPoint = CGPoint(x: 0.35, y: 0.65)   // (0.35, 0.35) from the top-left; layers here are bottom-left
        body.endPoint = CGPoint(x: 1.05, y: -0.05)
        root.addSublayer(body)

        let overlay = CAGradientLayer()
        overlay.type = .conic
        overlay.frame = body.bounds
        overlay.colors = aurora
        overlay.startPoint = CGPoint(x: 0.5, y: 0.5)
        overlay.endPoint = CGPoint(x: 1, y: 0.5)
        overlay.opacity = 0.55
        body.addSublayer(overlay)

        guard animate else { return }
        let breatheOpacity = CABasicAnimation(keyPath: "opacity")
        breatheOpacity.fromValue = 0.35
        breatheOpacity.toValue = 0.7
        let breatheScale = CABasicAnimation(keyPath: "transform.scale")
        breatheScale.fromValue = 1.0
        breatheScale.toValue = 1.15
        for (key, animation) in [("breatheOpacity", breatheOpacity), ("breatheScale", breatheScale)] {
            animation.duration = 1.2   // autoreversed: a 2.4 s period
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = false
            halo.add(animation, forKey: key)
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 12
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        overlay.add(spin, forKey: "spin")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downLocation = NSEvent.mouseLocation
        downCenter = window.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downLocation, let window else { return }
        let now = NSEvent.mouseLocation
        if !dragged, !OrbPlacement.isDrag(from: downLocation, to: now) { return }
        dragged = true
        window.setFrame(OrbPlacement.panelFrame(center: CGPoint(x: downCenter.x + now.x - downLocation.x,
                                                               y: downCenter.y + now.y - downLocation.y)), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard downLocation != nil else { return }
        downLocation = nil
        let center = window.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? downCenter
        onMouseUp(dragged, center)
    }
}
