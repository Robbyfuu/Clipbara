import AppKit

enum PanelGeometry {
    static let height: CGFloat = 300

    /// Full width of the visible area, flush with its bottom edge.
    static func frame(visibleFrame: NSRect, height: CGFloat) -> NSRect {
        NSRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: min(height, visibleFrame.height)
        )
    }
}
