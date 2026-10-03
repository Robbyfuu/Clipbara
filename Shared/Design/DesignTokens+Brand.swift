import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DesignTokens {}

extension DesignTokens {
    // MARK: - Copyd brand

    enum Brand {
        static let shelf = dynamic(light: 0xF2F0E9, dark: 0x12121A)
        static let card = dynamic(light: 0xFEFDFB, dark: 0x1E1E29)
        static let line = dynamic(light: 0xD8D8E0, dark: 0x32323D)
        static let ink = dynamic(light: 0x191926, dark: 0xF3F2ED)
        static let ink2 = dynamic(light: 0x575763, dark: 0xA9AAB4)
        static let chip = dynamic(light: 0xE4E1D9, dark: 0x2A2A35)
        static let butter = dynamic(light: 0xF8D14F, dark: 0xF8D14F)
        static let onButter = dynamic(light: 0x191926, dark: 0x191926)
        /// Liquid Glass tint (macOS 26+): faint paper / ink keeps text legible over any wallpaper.
        static let glassTint = dynamic(light: 0xF2F0E9, dark: 0x12121A, alpha: 0.4)

        #if os(macOS)
        private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? nsColor(hex: dark, alpha: alpha) : nsColor(hex: light, alpha: alpha)
            })
        }

        private static func nsColor(hex: UInt32, alpha: CGFloat) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        }
        #else
        private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
            Color(uiColor: UIColor { traits in
                uiColor(hex: traits.userInterfaceStyle == .dark ? dark : light, alpha: alpha)
            })
        }

        private static func uiColor(hex: UInt32, alpha: CGFloat) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        }
        #endif
    }

    /// Pinboard dot palette, identical in light and dark. Index via `PinboardDot.index(for:)`.
    static let pinboardDots: [Color] = [0x4C9DEB, 0x4EB068, 0xE17363, 0xAD80DD, 0x00B1BA, 0xCE871B].map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }
}
