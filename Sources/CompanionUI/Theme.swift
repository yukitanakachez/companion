import AppKit
import SwiftUI

/// The approved mockup's tokens (bubble-flow.html).
enum Theme {
    static let bubbleFill = Color(hex: 0x1C1C1E).opacity(0.92)
    static let text = Color(hex: 0xF2F2F7)
    static let chipBackground = Color.white.opacity(0.12)
    static let chipText = Color(hex: 0xD8D8DE)
    static let chipRadius: CGFloat = 6
    static let chipCloseOpacity = 0.55
    static let hairline = Color.white.opacity(0.25)
    static let inputBackground = Color.white.opacity(0.08)
    static let inputRadius: CGFloat = 8
    static let accent = Color(hex: 0x0A84FF)
    static let accentNS = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
    static let placeholder = Color(hex: 0x8E8E93)
    static let footer = Color(hex: 0x8E8E93)
    static let stepText = Color(hex: 0xD1D1D6)
    static let stepDone = Color(hex: 0x30D158)
    static let stepActive = Color(hex: 0xFFD60A)
    static let stepFailed = Color(hex: 0xFF453A)
    static let windowThumb = CGSize(width: 26, height: 17)
    static let pageThumb = CGSize(width: 34, height: 44)
    static let aurora = [Color(hex: 0xFF5FA2), Color(hex: 0xFFB35C), Color(hex: 0x6E7BFF), Color(hex: 0x37E0D0)]
    static let auroraCG: [CGColor] = [0xFF5FA2, 0xFFB35C, 0x6E7BFF, 0x37E0D0].map { cgColor(hex: $0) }

    static func cgColor(hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
