import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The "copy" + mark lockup. The mark stands in for the "d": 1.4 x-heights tall, sitting on the baseline.
struct CopydWordmark: View {
    var size: CGFloat

    var body: some View {
        let xHeight = Self.xHeight(size)
        // CopydMark draws into a square of 64 units; its visible box is 40 wide (from x 0) and 56 tall (from y 4).
        let markSize = xHeight * 1.4 * 64 / 56
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text("copy")
                .font(.system(size: size, weight: .heavy))
                .tracking(-0.045 * size)
                .foregroundStyle(DesignTokens.Brand.ink)
            CopydMark(size: markSize)
                .offset(y: -markSize * 4 / 64)
                .frame(width: xHeight, height: xHeight * 1.4, alignment: .topLeading)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copyd")
    }

    private static func xHeight(_ size: CGFloat) -> CGFloat {
        #if os(macOS)
        NSFont.systemFont(ofSize: size, weight: .heavy).xHeight
        #else
        UIFont.systemFont(ofSize: size, weight: .heavy).xHeight
        #endif
    }
}
