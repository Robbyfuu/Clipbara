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
