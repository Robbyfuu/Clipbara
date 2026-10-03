import SwiftUI

/// Butter primary button; `butterInk` at 20 % darkens it while pressed.
struct ButterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        configuration.label
            .background(DesignTokens.Brand.butter, in: shape)
            .overlay { if configuration.isPressed { shape.fill(DesignTokens.Brand.butterInk.opacity(0.2)) } }
            .contentShape(shape)
    }
}
