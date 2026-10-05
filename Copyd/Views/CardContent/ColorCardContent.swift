import SwiftUI
import AppKit

struct ColorCardContent: View {
    let item: ClipboardItem

    private var color: Color {
        Color(nsColor: NSColor.fromHex(item.textContent ?? "#000000") ?? .black)
    }

    var body: some View {
        color.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
