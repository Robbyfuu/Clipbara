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
        /// Light text on a dark app color in a card header (`ContrastPicker`'s `.light`). Dark text is `onButter`.
        static let onDark = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
        /// Soft butter ground for the iOS sync chip.
        static let butterSoft = dynamic(light: 0xFCF1C8, dark: 0x3A3420)
        /// Butter-toned text ("Pinned"). On `card`: 4.99:1 light, 11.17:1 dark.
        static let butterInk = dynamic(light: 0x8A6A00, dark: 0xF8D14F)
        /// Keyboard key surface: lighter than the system keyboard background in both modes, like native keys.
        static let keyCap = dynamic(light: 0xFEFDFB, dark: 0x3B3B48)
        static let keyCapPressed = dynamic(light: 0xD8D8E0, dark: 0x4C4C5A)
        /// The hard 1 pt shadow under a key cap: dark in both modes (ink turns light in dark mode).
        static let keyShadow = dynamic(light: 0x191926, dark: 0x000000, alpha: 0.35)
        /// Liquid Glass tint (macOS 26+): faint paper / ink keeps text legible over any wallpaper.
        static let glassTint = dynamic(light: 0xF2F0E9, dark: 0x12121A, alpha: 0.4)
        /// Code colors, one per `CodeTokenKind`. Other code text stays `ink`. Each is at least 4.5:1 on `card` and
        /// `chip` in both modes (`CodeColorContrastTests`).
        static let codeKeyword = dynamic(light: 0x7A3EB1, dark: 0xC792EA)
        static let codeString = dynamic(light: 0x1F6B25, dark: 0xA5D6A7)
        static let codeComment = dynamic(light: 0x5A606A, dark: 0x9CA2AD)
        static let codeNumber = dynamic(light: 0x964A00, dark: 0xF6B26B)

        static func code(_ kind: CodeTokenKind) -> Color {
            switch kind {
            case .keyword: codeKeyword
            case .string: codeString
            case .comment: codeComment
            case .number: codeNumber
            }
        }

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
