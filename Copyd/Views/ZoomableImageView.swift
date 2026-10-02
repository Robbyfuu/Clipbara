import SwiftUI
import AppKit

/// Zoom state shared between the Quick Look toolbar, the panel key monitor,
/// and the AppKit scroll view that actually renders the image.
@MainActor
final class ImageZoomController: ObservableObject {
    @Published fileprivate(set) var magnification: CGFloat = 1
    @Published fileprivate(set) var isFitted = true
    @Published fileprivate(set) var canZoomIn = true
    @Published fileprivate(set) var canZoomOut = false

    fileprivate weak var scrollView: ZoomingImageScrollView?

    enum Action {
        case zoomIn
        case zoomOut
        case fit
    }

    func perform(_ action: Action) {
        switch action {
        case .zoomIn: scrollView?.zoom(by: ZoomingImageScrollView.stepFactor)
        case .zoomOut: scrollView?.zoom(by: 1 / ZoomingImageScrollView.stepFactor)
        case .fit: scrollView?.fitToView()
        }
    }

    /// Fit <-> 100%, the same toggle as a double-click.
    func toggleFitAndActualSize() {
        scrollView?.toggleFitAndActualSize(at: nil)
    }

    fileprivate func sync(from scrollView: ZoomingImageScrollView) {
        let magnification = scrollView.magnification
        if abs(self.magnification - magnification) > 0.0001 { self.magnification = magnification }
        if isFitted != scrollView.isFitted { isFitted = scrollView.isFitted }
        let canZoomIn = magnification < scrollView.maxMagnification - 0.0001
        let canZoomOut = magnification > scrollView.minMagnification + 0.0001
        if self.canZoomIn != canZoomIn { self.canZoomIn = canZoomIn }
        if self.canZoomOut != canZoomOut { self.canZoomOut = canZoomOut }
    }

    /// Cmd+= / Cmd+Shift+= / Cmd+- / Cmd+0 on the number row and keypad.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        let chord = modifiers.intersection([.command, .option, .control])
        guard chord == .command else { return nil }
        switch keyCode {
        case 24, 69: return .zoomIn   // = (and + with Shift), keypad +
        case 27, 78: return .zoomOut  // -, keypad -
        case 29, 82: return .fit      // 0, keypad 0
        default: return nil
        }
    }
}

/// Image viewer for Quick Look: fits the whole image by default, then zooms with
/// pinch, Cmd/Option + scroll, double-click, Cmd+= / Cmd+- / Cmd+0, and pans by
/// scrolling or dragging.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let controller: ImageZoomController

    func makeNSView(context: Context) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView(image: image)
        scrollView.onZoomChange = { [weak controller] view in
            controller?.sync(from: view)
        }
        controller.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ nsView: ZoomingImageScrollView, context: Context) {
        controller.scrollView = nsView
        if nsView.image !== image {
            nsView.setImage(image)
        }
    }
}

final class ZoomingImageScrollView: NSScrollView {
    static let stepFactor: CGFloat = 1.25
    /// Breathing room around the image in fit mode, in view points.
    static let fitMargin: CGFloat = 16

    private let imageView: CheckeredImageView
    private(set) var isFitted = true
    private var lastLaidOutSize: CGSize = .zero
    private var dragOrigin: (point: NSPoint, visibleOrigin: NSPoint)?
    var onZoomChange: ((ZoomingImageScrollView) -> Void)?

    var image: NSImage { imageView.image }

    init(image: NSImage) {
        imageView = CheckeredImageView(image: image)
        super.init(frame: .zero)

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        maxMagnification = 16
        documentView = imageView

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: NSImage) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        lastLaidOutSize = .zero
        isFitted = true
        needsLayout = true
    }

    // MARK: - Fit

    /// Largest magnification that shows the whole image, never upscaling past 100%.
    var fitMagnification: CGFloat {
        let imageSize = imageView.image.size
        let available = CGSize(
            width: bounds.width - Self.fitMargin * 2,
            height: bounds.height - Self.fitMargin * 2
        )
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / imageSize.width, available.height / imageSize.height)
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size

        let fit = fitMagnification
        minMagnification = min(fit, 1)
        if isFitted {
            applyFit()
        } else {
            onZoomChange?(self)
        }
    }

    func fitToView() {
        isFitted = true
        applyFit()
    }

    private func applyFit() {
        let fit = fitMagnification
        minMagnification = min(fit, 1)
        magnification = fit
        isFitted = true
        imageView.needsDisplay = true
        onZoomChange?(self)
    }

    // MARK: - Zoom

    func zoom(by factor: CGFloat, centeredAt point: NSPoint? = nil) {
        let target = (magnification * factor).clamped(to: minMagnification...maxMagnification)
        setZoom(target, centeredAt: point ?? visibleCenter)
    }

    /// Double-click behaviour: fitted (or zoomed out) goes to 100%, anything else back to fit.
    /// A small image that already fits at 100% zooms to 200% instead, so the toggle always does something.
    func toggleFitAndActualSize(at point: NSPoint?) {
        let center = point ?? visibleCenter
        if isFitted || magnification < 1 - 0.0001 {
            let target: CGFloat = fitMagnification >= 1 - 0.0001 ? 2 : 1
            setZoom(min(target, maxMagnification), centeredAt: center)
        } else {
            fitToView()
        }
    }

    private func setZoom(_ target: CGFloat, centeredAt point: NSPoint) {
        let fit = fitMagnification
        if abs(target - fit) < 0.0001 {
            fitToView()
            return
        }
        isFitted = false
        setMagnification(target, centeredAt: point)
        imageView.needsDisplay = true
        onZoomChange?(self)
    }

    private var visibleCenter: NSPoint {
        let visible = contentView.bounds
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    @objc private func clipBoundsDidChange(_ note: Notification) {
        // Pinch and live magnification land here. Anything other than the fit
        // magnification means the user has taken over the zoom level.
        if isFitted, abs(magnification - fitMagnification) > 0.0001 {
            isFitted = false
        }
        imageView.needsDisplay = true
        onZoomChange?(self)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if event.phase == .ended || event.phase == .cancelled {
            snapToFitIfClose()
        }
    }

    private func snapToFitIfClose() {
        let fit = fitMagnification
        if !isFitted, abs(magnification - fit) / max(fit, 0.0001) < 0.03 {
            fitToView()
        }
    }

    // MARK: - Mouse

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option])
        guard !modifiers.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
        let factor = exp(delta * sensitivity)
        let point = imageView.convert(event.locationInWindow, from: nil)
        zoom(by: factor, centeredAt: point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragOrigin = nil
            let point = imageView.convert(event.locationInWindow, from: nil)
            toggleFitAndActualSize(at: point)
            return
        }
        dragOrigin = (event.locationInWindow, contentView.bounds.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, isScrollable else { return }
        NSCursor.closedHand.set()
        let dx = (event.locationInWindow.x - dragOrigin.point.x) / magnification
        let dy = (event.locationInWindow.y - dragOrigin.point.y) / magnification
        var origin = dragOrigin.visibleOrigin
        origin.x -= dx
        origin.y += imageView.isFlipped ? dy : -dy
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        NSCursor.arrow.set()
    }

    /// True when the zoomed image is larger than the viewport in either axis.
    private var isScrollable: Bool {
        let doc = imageView.frame.size
        let visible = contentView.bounds.size
        return doc.width > visible.width + 0.5 || doc.height > visible.height + 0.5
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isScrollable {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// Keeps the document centered when it is smaller than the viewport.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width {
            rect.origin.x = doc.minX - (rect.width - doc.width) / 2
        }
        if rect.height > doc.height {
            rect.origin.y = doc.minY - (rect.height - doc.height) / 2
        }
        return rect
    }
}

/// Draws a transparency checkerboard behind the image only, with cells that stay
/// the same on-screen size at every zoom level.
private final class CheckeredImageView: NSView {
    var image: NSImage {
        didSet { needsDisplay = true }
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let magnification = enclosingScrollView?.magnification ?? 1
        let cell = 8 / max(magnification, 0.0001)
        let light = NSColor(white: 0.21, alpha: 1)
        let dark = NSColor(white: 0.16, alpha: 1)

        let clip = dirtyRect.intersection(bounds)
        dark.setFill()
        clip.fill()
        light.setFill()
        let firstCol = Int(floor(clip.minX / cell))
        let lastCol = Int(ceil(clip.maxX / cell))
        let firstRow = Int(floor(clip.minY / cell))
        let lastRow = Int(ceil(clip.maxY / cell))
        if lastCol >= firstCol, lastRow >= firstRow {
            for row in firstRow...lastRow {
                for col in firstCol...lastCol where (row + col) % 2 == 0 {
                    NSRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        .intersection(clip)
                        .fill()
                }
            }
        }

        // Past 200% show real pixels instead of a blurry upscale.
        NSGraphicsContext.current?.imageInterpolation = magnification > 2 ? .none : .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
