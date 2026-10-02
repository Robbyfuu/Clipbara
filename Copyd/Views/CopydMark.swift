import SwiftUI

/// The Copyd mark: a butter card with a counter hole and an ink stem.
/// Geometry is the 64-unit artboard (original viewBox "-6 0 64 64").
struct CopydMark: View {
    var size: CGFloat
    var stemColor: Color? = nil

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 64
            let transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -6, y: 0)

            var card = Path(roundedRect: CGRect(x: 6, y: 20, width: 40, height: 40), cornerRadius: 14)
            card.addEllipse(in: CGRect(x: 12, y: 33, width: 14, height: 14))
            context.fill(card.applying(transform), with: .color(DesignTokens.Brand.butter), style: FillStyle(eoFill: true))

            let stem = Path(roundedRect: CGRect(x: 32, y: 4, width: 14, height: 56), cornerRadius: 7)
            context.fill(stem.applying(transform), with: .color(stemColor ?? DesignTokens.Brand.ink))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
