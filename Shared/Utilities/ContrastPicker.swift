import Foundation

enum TextTone: Equatable, Sendable { case light, dark }

/// Picks the header text tone for an app color by WCAG contrast.
enum ContrastPicker {
    /// `Brand.onButter`, the dark ink in both modes. The light tone is white (`Brand.onDark`).
    static let darkInk = RGB(r: 0x19 / 255, g: 0x19 / 255, b: 0x26 / 255)
    private static let white = RGB(r: 1, g: 1, b: 1)

    /// Dark ink when it reads at least as well as white.
    static func textColor(on fill: RGB) -> TextTone {
        ratio(darkInk, fill) >= ratio(white, fill) ? .dark : .light
    }

    /// WCAG contrast ratio, 1...21, in either order.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }
}
