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

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? nsColor(hex: dark) : nsColor(hex: light)
            })
        }

        private static func nsColor(hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    /// Pinboard dot palette, identical in light and dark. Index via `PinboardDot.index(for:)`.
    static let pinboardDots: [Color] = [0x4C9DEB, 0x4EB068, 0xE17363, 0xAD80DD, 0x00B1BA, 0xCE871B].map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    static func headerColor(for contentType: ContentType, itemColor: String? = nil) -> Color {
        typeTint(for: contentType, itemColor: itemColor)
    }

    // MARK: - Card

    enum Card {
        static let cornerRadius: CGFloat = 8
        static let topPadding: CGFloat = 8
        static let horizontalPadding: CGFloat = 10
        static let contentSpacing: CGFloat = 6

        static func backgroundColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(white: 0.115)
                : Color(white: 0.99)
        }

        static func borderColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.black.opacity(0.08)
        }
    }

    // MARK: - Card Header

    enum Header {
        static let titleFont: Font = .system(size: 12, weight: .semibold)
        static let subtitleFont: Font = .system(size: 11, weight: .regular)
        static let subtitleOpacity: Double = 0.8
        static let appIconSize: CGFloat = 26
        static let appIconCornerRadius: CGFloat = 6
        static let badgeVerticalPadding: CGFloat = 3
        static let badgeHorizontalPadding: CGFloat = 7
        static let badgeCornerRadius: CGFloat = 6
    }

    // MARK: - Card Body

    enum Body {
        static let padding: CGFloat = 10
        static let fontSize: CGFloat = 12
        static let lineSpacing: CGFloat = 4
        static let maxLines: Int = 4

        static func textColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(white: 0.88)
                : Color(white: 0.20)
        }
    }

    // MARK: - Card Footer Badge

    enum Badge {
        static let font: Font = .system(size: 11, weight: .medium)
        static let verticalPadding: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 8

        static func backgroundColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.06)
        }

        static func textColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(white: 0.62)
                : Color(white: 0.40)
        }
    }

    // MARK: - Card Selection

    enum Selection {
        static let borderColor = Brand.butter
        static let borderWidth: CGFloat = 2.25
        static let defaultBorderWidth: CGFloat = 0.75
        static let selectedShadowOpacity: Double = 0.24
        static let selectedShadowRadius: CGFloat = 12
        static let defaultShadowOpacity: Double = 0.06
        static let defaultShadowRadius: CGFloat = 2
        static let hoverShadowOpacity: Double = 0.20
        static let hoverShadowRadius: CGFloat = 12
        static let hoverScale: CGFloat = 1.035
        static let hoverLift: CGFloat = -3
        static let hoverBorderWidth: CGFloat = 1.25
    }

    // MARK: - Navigation Bar

    enum Nav {
        static let height: CGFloat = 56
        static let horizontalPadding: CGFloat = 16
        static let tabHeight: CGFloat = 28
        static let tabCornerRadius: CGFloat = 8
        static let activeFont: Font = .system(size: 13, weight: .medium)
        static let inactiveFont: Font = .system(size: 13, weight: .regular)
        static let dotSize: CGFloat = 8
        static let searchIconSize: CGFloat = 16
        static let searchWidth: CGFloat = 260

        static func activeBackground(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.black.opacity(0.06)
        }

        static func searchBackground(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.08)
        }

        static func activeTextColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(white: 0.95)
                : Color(white: 0.16)
        }

        static func inactiveTextColor(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(white: 0.75)
                : Color(white: 0.38)
        }
    }

    // MARK: - Checkerboard

    enum Checkerboard {
        static let cellSize: CGFloat = 8
        static let lightColor = Color.white
        static let darkColor = Color(white: 0.96) // #F5F5F5
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
