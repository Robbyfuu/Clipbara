import Foundation
#if canImport(AppKit)
import AppKit
typealias MarkdownFont = NSFont
#else
import UIKit
typealias MarkdownFont = UIFont
#endif

/// "Paste as → Markdown" from a formatted clip, and "Paste as → Formatted text" from Markdown. Pure: callers run it off
/// the main actor, RTF decoding included.
enum MarkdownConverter {
    /// A finished paragraph, heading, item or code block. Items of one list join with one newline, the rest with a blank line.
    private struct Block {
        let text: String
        var list: Int?
    }

    private static func joined(_ blocks: [Block]) -> String {
        var out = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += block.list != nil && block.list == blocks[index - 1].list ? "\n" : "\n\n" }
            out += block.text
        }
        return out
    }

    // MARK: HTML

    /// A tag subset: `h1`–`h6`, `p`, `br`, `b`/`strong`, `i`/`em`, `a`, `ul`/`ol`/`li` (nested), `code`, `pre` and
    /// `blockquote`. Other tags are dropped and their text kept; scripts, styles and the head are dropped whole.
    /// Entities are decoded. Malformed HTML gives its text, never a crash.
    static func markdown(fromHTML html: String) -> String {
        var writer = HTMLWriter()
        var index = html.startIndex
        let end = html.endIndex
        while index < end {
            guard let open = html[index...].firstIndex(of: "<") else {
                writer.text(html[index...])
                break
            }
            writer.text(html[index..<open])
            let next = html.index(after: open)
            if html[open...].hasPrefix("<!--") {
                index = html[next...].range(of: "-->")?.upperBound ?? end
                continue
            }
            // A "<" that opens no tag is text: "a < b".
            guard next < end, html[next].isLetter || "/!?".contains(html[next]) else {
                writer.text(html[open..<next])
                index = next
                continue
            }
            // A tag never closed ends the document.
            guard let close = tagEnd(html, from: next) else { break }
            writer.tag(html[next..<close])
            index = html.index(after: close)
        }
        return writer.finish()
    }

    /// The `>` closing a tag. A quote right after `=` opens a value that may hold `>`.
    private static func tagEnd(_ html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var previous: Character = " "
        var index = start
        while index < html.endIndex {
            let character = html[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == ">" {
                return index
            } else if character == "\"" || character == "'", previous == "=" {
                quote = character
            }
            if !character.isWhitespace { previous = character }
            index = html.index(after: index)
        }
        return nil
    }

    private static let skippedTags: Set<String> = ["script", "style", "head", "title", "template", "noscript"]
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure", "figcaption", "table",
        "tr", "thead", "tbody", "tfoot", "hr", "dl", "dt", "dd", "address", "center", "form", "fieldset", "details", "summary",
    ]

    private struct HTMLWriter {
        enum Kind { case bold, italic, code, link }
        struct Inline {
            let kind: Kind
            let open: String
            let close: String
        }
        struct List {
            let ordered: Bool
            var count = 0
            /// What the next line of the current item starts with: its marker, then spaces under it.
            var prefix: String?
        }

        var blocks: [Block] = []
        var line = ""
        var pendingSpace = false
        /// Open inline elements. Those at `emitted` and above have not written their opening marker yet: it goes in
        /// before the next character, so `<b> </b>` writes nothing and `<b>a </b>` writes `**a**`.
        var inlines: [Inline] = []
        var emitted = 0
        var lists: [List] = []
        var listGroup = 0
        var heading: Int?
        var quoteDepth = 0
        var preDepth = 0
        var skipDepth = 0

        mutating func text(_ raw: Substring) {
            guard skipDepth == 0, !raw.isEmpty else { return }
            let text = MarkdownConverter.decodeEntities(raw)
            if preDepth > 0 { return line += text }
            for character in text {
                if character.isWhitespace {
                    if let last = line.last, last != "\n" { pendingSpace = true }
                    continue
                }
                if pendingSpace {
                    line.append(" ")
                    pendingSpace = false
                }
                for inline in inlines[emitted...] { line += inline.open }
                emitted = inlines.count
                line.append(character)
            }
        }

        mutating func tag(_ raw: Substring) {
            var body = raw
            let closing = body.first == "/"
            if closing { body = body.dropFirst() }
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            guard !name.isEmpty else { return }
            if MarkdownConverter.skippedTags.contains(name) {
                skipDepth = closing ? max(0, skipDepth - 1) : skipDepth + 1
                return
            }
            guard skipDepth == 0 else { return }
            switch name {
            case "b", "strong": closing ? closeInline(.bold) : openInline(.bold, "**", "**")
            case "i", "em": closing ? closeInline(.italic) : openInline(.italic, "*", "*")
            case "code": closing ? closeInline(.code) : openInline(.code, "`", "`")
            case "a":
                if closing { return closeInline(.link) }
                let href = MarkdownConverter.attribute("href", in: body.dropFirst(name.count))
                    .map { MarkdownConverter.decodeEntities($0[...]).trimmingCharacters(in: .whitespaces) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                if let href {
                    let escaped = href.replacingOccurrences(of: " ", with: "%20")
                        .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                    openInline(.link, "[", "](\(escaped))")
                } else {
                    openInline(.link, "", "")
                }
            case "br":
                if preDepth > 0 || !line.isEmpty { line += "\n" }
                pendingSpace = false
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                heading = closing ? nil : Int(name.dropFirst())
            case "ul", "ol":
                flush()
                if closing {
                    if !lists.isEmpty { lists.removeLast() }
                } else {
                    if lists.isEmpty { listGroup += 1 }
                    lists.append(List(ordered: name == "ol"))
                }
            case "li":
                flush()
                if lists.isEmpty {
                    listGroup += 1
                    lists.append(List(ordered: false))
                }
                let last = lists.count - 1
                if closing { return lists[last].prefix = nil }
                lists[last].count += 1
                let marker = lists[last].ordered ? "\(lists[last].count). " : "- "
                // Under the parent item's text: its prefix holds its own indent already.
                let indent = last > 0 ? lists[last - 1].prefix?.count ?? 2 * last : 0
                lists[last].prefix = String(repeating: " ", count: indent) + marker
            case "pre":
                if closing {
                    guard preDepth > 0 else { return }
                    preDepth -= 1
                    if preDepth == 0 { closePre() }
                } else {
                    if preDepth == 0 { flush() }
                    preDepth += 1
                }
            case "blockquote":
                flush()
                quoteDepth = closing ? max(0, quoteDepth - 1) : quoteDepth + 1
            case "td", "th":
                if !line.isEmpty { pendingSpace = true }
            default:
                if MarkdownConverter.blockTags.contains(name) { flush() }
            }
        }

        /// No markers inside code; a kind already open nests as a no-op, so its close still matches.
        private mutating func openInline(_ kind: Kind, _ open: String, _ close: String) {
            let literal = preDepth > 0 || inlines.contains { $0.kind == .code || $0.kind == kind }
            inlines.append(Inline(kind: kind, open: literal ? "" : open, close: literal ? "" : close))
        }

        /// Closes the innermost `kind` and the elements opened inside it; those reopen before the next character.
        private mutating func closeInline(_ kind: Kind) {
            guard let index = inlines.lastIndex(where: { $0.kind == kind }) else { return }
            for inner in (index..<inlines.count).reversed() where inner < emitted { line += inlines[inner].close }
            inlines.remove(at: index)
            emitted = min(emitted, index)
        }

        /// Ends the current block. Open inline elements close here and reopen in the next one.
        mutating func flush() {
            guard preDepth == 0 else { return }
            for inline in inlines[..<emitted].reversed() { line += inline.close }
            emitted = 0
            let body = line.trimmingCharacters(in: .whitespacesAndNewlines)
            line = ""
            pendingSpace = false
            guard !body.isEmpty else { return }
            var first = ""
            var rest = ""
            if let heading {
                first = String(repeating: "#", count: heading) + " "
            } else if let prefix = lists.last?.prefix {
                first = prefix
                rest = String(repeating: " ", count: prefix.count)
                lists[lists.count - 1].prefix = rest
            }
            let quote = String(repeating: "> ", count: quoteDepth)
            let text = body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { quote + ($0.offset == 0 ? first : rest) + $0.element }
                .joined(separator: "\n")
            blocks.append(Block(text: text, list: lists.isEmpty || heading != nil ? nil : listGroup))
        }

        private mutating func closePre() {
            var code = line
            line = ""
            if code.hasPrefix("\n") { code.removeFirst() }
            while code.last?.isNewline == true { code.removeLast() }
            guard !code.isEmpty else { return }
            let quote = String(repeating: "> ", count: quoteDepth)
            let text = ("```\n" + code + "\n```").split(separator: "\n", omittingEmptySubsequences: false)
                .map { quote + $0 }.joined(separator: "\n")
            blocks.append(Block(text: text, list: nil))
        }

        mutating func finish() -> String {
            if preDepth > 0 {
                preDepth = 0
                closePre()
            }
            flush()
            return MarkdownConverter.joined(blocks)
        }
    }

    /// An attribute's value: quoted, or up to the next space.
    fileprivate static func attribute(_ name: String, in attributes: Substring) -> String? {
        var rest = attributes
        while let match = rest.range(of: name, options: .caseInsensitive) {
            let before = match.lowerBound == attributes.startIndex ? " " : attributes[attributes.index(before: match.lowerBound)]
            var value = rest[match.upperBound...].drop { $0.isWhitespace }
            if before.isWhitespace, value.first == "=" {
                value = value.dropFirst().drop { $0.isWhitespace }
                if let quote = value.first, quote == "\"" || quote == "'" {
                    return String(value.dropFirst().prefix { $0 != quote })
                }
                return String(value.prefix { !$0.isWhitespace && $0 != "/" })
            }
            rest = rest[match.upperBound...]
        }
        return nil
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•",
        "middot": "·", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "euro": "€", "shy": "\u{00AD}",
    ]

    /// Named entities from a common subset, and every valid numeric one. Anything else stays as written.
    fileprivate static func decodeEntities(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        var out = ""
        var index = text.startIndex
        while let amp = text[index...].firstIndex(of: "&") {
            out += text[index..<amp]
            let start = text.index(after: amp)
            if let semicolon = text[start...].prefix(12).firstIndex(of: ";"), let decoded = entity(text[start..<semicolon]) {
                out += decoded
                index = text.index(after: semicolon)
            } else {
                out += "&"
                index = start
            }
        }
        return out + text[index...]
    }

    private static func entity(_ name: Substring) -> String? {
        guard name.first == "#" else { return entities[String(name)] }
        let number = name.dropFirst()
        let hex = number.first == "x" || number.first == "X"
        guard let value = UInt32(hex ? number.dropFirst() : number, radix: hex ? 16 : 10), value != 0,
              let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    // MARK: Attributed string

    /// From an attributed string, as RTF decodes: bold and italic fonts, links, text lists, and headings by size (at
    /// least 1.6× the body is `#`, at least 1.3× is `##`; the body is the most common size).
    static func markdown(from string: NSAttributedString) -> String {
        let text = string.string as NSString
        guard text.length > 0 else { return "" }
        let body = bodySize(of: string)
        var blocks: [Block] = []
        var counts: [Int] = []
        var group = 0
        var inList = false
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var range = paragraph
            while range.length > 0, let last = Unicode.Scalar(text.character(at: NSMaxRange(range) - 1)),
                  CharacterSet.newlines.contains(last) { range.length -= 1 }
            let lists = (string.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textLists ?? []
            // The marker the Mac's text system types into the text: "\t•\t", "\t1.\t".
            if !lists.isEmpty, text.substring(with: range).hasPrefix("\t") {
                let marker = text.range(of: "\t", range: NSRange(location: range.location + 1, length: min(range.length - 1, 12)))
                if marker.location != NSNotFound {
                    range = NSRange(location: NSMaxRange(marker), length: NSMaxRange(range) - NSMaxRange(marker))
                }
            }
            guard !text.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            if lists.isEmpty {
                inList = false
                counts = []
                let largest = maxSize(of: string, in: range) / body
                if largest >= 1.3 {
                    let title = text.substring(with: range).trimmingCharacters(in: .whitespaces)
                    blocks.append(Block(text: (largest >= 1.6 ? "# " : "## ") + title, list: nil))
                } else {
                    blocks.append(Block(text: inlineMarkdown(string, range), list: nil))
                }
                continue
            }
            if !inList {
                group += 1
                inList = true
            }
            let depth = lists.count
            counts = Array(counts.prefix(depth))
            while counts.count < depth { counts.append(0) }
            counts[depth - 1] += 1
            let list = lists[depth - 1]
            let marker = isOrdered(list) ? "\(list.startingItemNumber - 1 + counts[depth - 1]). " : "- "
            let indent = lists.dropLast().map { String(repeating: " ", count: isOrdered($0) ? 3 : 2) }.joined()
            blocks.append(Block(text: indent + marker + inlineMarkdown(string, range), list: group))
        }
        return joined(blocks)
    }

    private static let unorderedMarkers: Set<NSTextList.MarkerFormat> = [.disc, .circle, .square, .hyphen, .box, .check, .diamond]

    private static func isOrdered(_ list: NSTextList) -> Bool { !unorderedMarkers.contains(list.markerFormat) }

    /// The most common font size by character count; the smaller one on a tie. 12 pt where no font is set, as RTF.
    private static func bodySize(of string: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            counts[(value as? MarkdownFont)?.pointSize ?? 12, default: 0] += range.length
        }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 12
    }

    private static func maxSize(of string: NSAttributedString, in range: NSRange) -> CGFloat {
        var size: CGFloat = 0
        string.enumerateAttribute(.font, in: range) { value, _, _ in
            size = max(size, (value as? MarkdownFont)?.pointSize ?? 12)
        }
        return size
    }

    /// Runs with the same bold, italic and link join, so a color change inside bold text writes one `**…**`.
    private static func inlineMarkdown(_ string: NSAttributedString, _ range: NSRange) -> String {
        var out = ""
        var run: (text: String, bold: Bool, italic: Bool, link: String?)?
        func emit() {
            guard let run else { return }
            let core = run.text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return out += run.text }
            let lead = run.text.prefix { $0 == " " || $0 == "\t" }
            let trail = String(run.text.reversed().prefix { $0 == " " || $0 == "\t" })
            let marker = run.bold && run.italic ? "***" : run.bold ? "**" : run.italic ? "*" : ""
            var styled = marker + core + marker
            if let link = run.link { styled = "[" + styled + "](" + link + ")" }
            out += String(lead) + styled + trail
        }
        string.enumerateAttributes(in: range) { attributes, piece, _ in
            let traits = traits(of: attributes[.font] as? MarkdownFont)
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let text = (string.string as NSString).substring(with: piece)
            if let current = run, current.bold == traits.bold, current.italic == traits.italic, current.link == link {
                run?.text += text
            } else {
                emit()
                run = (text, traits.bold, traits.italic, link)
            }
        }
        emit()
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func traits(of font: MarkdownFont?) -> (bold: Bool, italic: Bool) {
        guard let traits = font?.fontDescriptor.symbolicTraits else { return (false, false) }
        #if canImport(AppKit)
        return (traits.contains(.bold), traits.contains(.italic))
        #else
        return (traits.contains(.traitBold), traits.contains(.traitItalic))
        #endif
    }

    // MARK: Markdown to formatted text

    private static let headingScale: [CGFloat] = [1.7, 1.4, 1.2, 1.1, 1, 1]

    /// Full Markdown parsing into Helvetica (Menlo for code), which every app reading the RTF has. Headings are bold and
    /// larger, list items get "• " or "1. ", and links keep their URL. Nil for empty text.
    static func attributed(fromMarkdown markdown: String, baseSize: CGFloat = 13) -> NSAttributedString? {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) else { return nil }
        let out = NSMutableAttributedString()
        var block: PresentationIntent?
        var item: Int?
        for run in parsed.runs {
            let intent = run.presentationIntent
            let kinds = intent?.components.map(\.kind) ?? []
            if out.length == 0 || intent != block {
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font(baseSize)])) }
                let listItem = intent?.components.first { if case .listItem = $0.kind { true } else { false } }
                if let listItem, listItem.identity != item, case .listItem(let ordinal) = listItem.kind {
                    let lists = kinds.filter { $0 == .orderedList || $0 == .unorderedList }
                    let marker = lists.first == .orderedList ? "\(ordinal). " : "• "
                    let indent = String(repeating: "    ", count: max(0, lists.count - 1))
                    out.append(NSAttributedString(string: indent + marker, attributes: [.font: font(baseSize)]))
                }
                item = listItem?.identity
                block = intent
            }
            let level = kinds.lazy.compactMap { if case .header(let level) = $0 { level } else { nil } }.first
            let codeBlock = kinds.contains { if case .codeBlock = $0 { true } else { false } }
            var text = String(parsed[run.range].characters)
            if codeBlock { while text.last?.isNewline == true { text.removeLast() } }
            let inline = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(level.map { baseSize * headingScale[min(max($0, 1), 6) - 1] } ?? baseSize,
                            bold: level != nil || inline.contains(.stronglyEmphasized), italic: inline.contains(.emphasized),
                            code: codeBlock || inline.contains(.code)),
            ]
            if let link = run.link { attributes[.link] = link }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }

    private static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false, code: Bool = false) -> MarkdownFont {
        let name = code
            ? ["Menlo-Regular", "Menlo-Italic", "Menlo-Bold", "Menlo-BoldItalic"][(bold ? 2 : 0) + (italic ? 1 : 0)]
            : ["Helvetica", "Helvetica-Oblique", "Helvetica-Bold", "Helvetica-BoldOblique"][(bold ? 2 : 0) + (italic ? 1 : 0)]
        return MarkdownFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }

    /// "Formatted text": the RTF to paste, and its plain text (the formatted text without its Markdown).
    static func formattedText(fromMarkdown markdown: String) -> (text: String, rtf: Data)? {
        guard let string = attributed(fromMarkdown: markdown),
              let rtf = try? string.data(from: NSRange(location: 0, length: string.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else { return nil }
        return (string.string, rtf)
    }

    /// An RTF clip's Markdown. Nil when the data isn't RTF. Never on the main actor: decoding a large RTF takes a while.
    static func markdown(fromRTF data: Data) -> String? {
        guard let string = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                   documentAttributes: nil) else { return nil }
        return markdown(from: string)
    }
}
