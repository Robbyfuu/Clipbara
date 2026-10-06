import AppKit
import SwiftUI
import XCTest

final class CodeColorContrastTests: XCTestCase {
    /// Every code color reads at WCAG AA (4.5:1) on the card and on the chip well, in light and in dark.
    @MainActor
    func testCodeColorsMeetAAOnCardAndChip() {
        let grounds = ["card": DesignTokens.Brand.card, "chip": DesignTokens.Brand.chip]
        for kind in [CodeTokenKind.keyword, .string, .comment, .number] {
            for mode in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, ground) in grounds {
                    let a = luminance(DesignTokens.Brand.code(kind), in: mode)
                    let b = luminance(ground, in: mode)
                    let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(kind) on \(name), \(mode.rawValue): \(ratio)")
                }
            }
        }
    }

    /// WCAG relative luminance of a dynamic Brand color, resolved for `mode`.
    @MainActor
    private func luminance(_ color: Color, in mode: NSAppearance.Name) -> Double {
        var resolved: NSColor?
        NSAppearance(named: mode)?.performAsCurrentDrawingAppearance { resolved = NSColor(color).usingColorSpace(.sRGB) }
        guard let rgb = resolved else { XCTFail("unresolvable color"); return 0 }
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { channel -> Double in
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
