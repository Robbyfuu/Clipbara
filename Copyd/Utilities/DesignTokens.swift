import SwiftUI

extension DesignTokens {
    // MARK: - Content Type Accent Colors

    static func typeTint(for contentType: ContentType, itemColor: String? = nil) -> Color {
        guard contentType == .color else { return Brand.ink2 }
        if let hex = itemColor {
            return Color(hex: hex) ?? Color.gray
        }
        return Color.gray
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
