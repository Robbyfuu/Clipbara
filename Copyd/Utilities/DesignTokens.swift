import SwiftUI

enum DesignTokens {
    // MARK: - Content Type Accent Colors

    static func typeTint(for contentType: ContentType, itemColor: String? = nil) -> Color {
        guard contentType == .color else { return Brand.ink2 }
        if let hex = itemColor {
            return Color(hex: hex) ?? Color.gray
        }
        return Color.gray
    }

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
    }

    /// Pinboard dot palette, identical in light and dark. Index via `PinboardDot.index(for:)`.
    static let pinboardDots: [Color] = [0x4C9DEB, 0x4EB068, 0xE17363, 0xAD80DD, 0x00B1BA, 0xCE871B].map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    // MARK: - Card

    enum Card {
        static let width: CGFloat = 200
        static let gridSpacing: CGFloat = 12
        static let gridLeadingPadding: CGFloat = 16
        static let height: CGFloat = 220
        static let padding: CGFloat = 10
        static let cornerRadius: CGFloat = 16
        static let wellRadius: CGFloat = 10
        static let ringWidth: CGFloat = 3
    }

    // MARK: - Card Selection

    enum Selection {
        static let defaultShadowOpacity: Double = 0.06
        static let defaultShadowRadius: CGFloat = 2
        static let hoverShadowOpacity: Double = 0.20
        static let hoverShadowRadius: CGFloat = 12
        static let hoverScale: CGFloat = 1.035
        static let hoverLift: CGFloat = -3
    }

    // MARK: - Navigation Bar

    enum Nav {
        static let height: CGFloat = 56
    }
}

// MARK: - Color hex init helper

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6,
              let hexNumber = UInt64(hexSanitized, radix: 16) else {
            return nil
        }

        let r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
        let g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
        let b = Double(hexNumber & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
