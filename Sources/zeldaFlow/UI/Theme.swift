import AppKit
import SwiftUI

/// zeldaLabs design tokens — the shared MD3-inspired violet system: warm
/// neutral surfaces, tonal containers. Light/dark adaptive.
enum Zelda {
    // Brand
    static let primary            = dyn(0x6D28D9, 0xC4B5FD)
    static let onPrimary          = dyn(0xFFFFFF, 0x2E1065)
    static let primaryContainer   = dyn(0xEDE9FE, 0x5B21B6)
    static let onPrimaryContainer = dyn(0x2E1065, 0xEDE9FE)
    static let tertiary           = dyn(0x4F46E5, 0xA5B4FC)

    // Neutrals
    static let background   = dyn(0xFBFAF7, 0x101411)
    static let surface1     = dyn(0xF4F3EF, 0x161A17)
    static let surface2     = dyn(0xEEEDE8, 0x1B1F1C)
    static let surface3     = dyn(0xE8E7E1, 0x202421)
    static let card         = dyn(0xFFFFFF, 0x161A17)
    static let border       = dyn(0xE1E3DD, 0x2A2E2B)
    static let foreground   = dyn(0x191C1A, 0xE2E3DD)
    static let mutedFg      = dyn(0x5C6360, 0xA0A8A2)

    // Domain accents (icon chips on stat cards)
    static let amber           = dyn(0xD97706, 0xE0A63E)
    static let amberContainer  = dyn(0xFEF3C7, 0x3A2E14)
    static let blue            = dyn(0x2563EB, 0x5C9EEA)
    static let blueContainer   = dyn(0xDBEAFE, 0x17304F)
    static let green           = dyn(0x16A34A, 0x3FC97C)
    static let greenContainer  = dyn(0xDCFCE7, 0x12362B)

    // MD3 shape scale
    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 12
    static let radiusLg: CGFloat = 16

    private static func dyn(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
