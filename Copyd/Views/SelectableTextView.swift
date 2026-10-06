import SwiftUI
import AppKit

struct SelectableTextView: NSViewRepresentable {
    let text: String
    var isMonospaced: Bool = false
    var fontSize: CGFloat = 14
    var lineSpacing: CGFloat = 5
    var contentInsets: NSEdgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    /// Code colors, as UTF-16 ranges of `text`.
    var codeRanges: [(range: NSRange, kind: CodeTokenKind)] = []
    /// Shown in place of `text` with its own fonts and links: Markdown formatted. Colors and spacing are this view's.
    var formatted: NSAttributedString?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            size: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        scrollView.documentView = textView
        scrollView.contentInsets = contentInsets

        applyText(to: textView, colorScheme: context.environment.colorScheme)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.contentInsets = contentInsets
        applyText(to: textView, colorScheme: context.environment.colorScheme)
    }

    private func applyText(to textView: NSTextView, colorScheme: ColorScheme) {
        let font: NSFont = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        let textColor: NSColor = colorScheme == .dark
            ? NSColor(white: 0.92, alpha: 1.0)
            : NSColor(white: 0.18, alpha: 1.0)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        let attributed: NSMutableAttributedString
        if let formatted {
            attributed = NSMutableAttributedString(attributedString: formatted)
            attributed.addAttributes([.foregroundColor: textColor, .paragraphStyle: paragraph],
                                     range: NSRange(location: 0, length: attributed.length))
        } else {
            attributed = NSMutableAttributedString(string: text, attributes: attributes)
        }
        for (range, kind) in codeRanges where NSMaxRange(range) <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: NSColor(DesignTokens.Brand.code(kind)), range: range)
        }
        // The Brand colors are dynamic: resolve them for the SwiftUI color scheme (Quick Look forces dark), not the app's.
        textView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        textView.textStorage?.setAttributedString(attributed)
    }
}
