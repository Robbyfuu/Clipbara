import Foundation
import SwiftData

/// "Paste as…" / "Copy as…" / "Insert as…": a different form of a clip's text, made at paste time. The clip stays as it is.
enum TextTransform: CaseIterable {
    case plain, upper, lower, title, trim, cleanLink, prettyJSON, compactJSON

    /// Clips whose text is the content. Colors, files and unknown data are not offered transforms or editing.
    static let textTypes: Set<ContentType> = [.plainText, .richText, .html, .url]
    /// A menu is worked out from at most this many bytes at the start of the text, so a long clip costs no more than
    /// a short one. It only decides what is offered: the pick applies to the whole text, and may then give nil.
    static let menuProbeLimit = 4096

    /// Query parameters that only track where a link came from. Matched without case; `utm_` and `_hs` are prefixes.
    private static let trackingNames: Set<String> = ["fbclid", "gclid", "mc_eid", "igshid", "si", "ref_src", "spm"]
    private static let trackingPrefixes = ["utm_", "_hs"]

    /// The transformed text, or nil when the transform doesn't apply: empty text, nothing would change, nothing would
    /// be left, invalid JSON, or no tracking parameter to remove. `plain` returns the text as is: what it removes is
    /// the formatting, which only the clip has.
    func apply(to text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let result: String?
        switch self {
        case .plain: return text
        case .upper: result = text.uppercased()
        case .lower: result = text.lowercased()
        case .title: result = text.capitalized
        case .trim: result = Self.trimmed(text)
        case .cleanLink: result = Self.cleanedLinks(text)
        case .prettyJSON: result = Self.reformattedJSON(text, pretty: true)
        case .compactJSON: result = Self.reformattedJSON(text, pretty: false)
        }
        guard let result, !result.isEmpty, result != text else { return nil }
        return result
    }

    /// The transforms that change this clip's text, in menu order, judged from its first `menuProbeLimit` bytes.
    /// `plain` only for formatted text. Longer JSON is offered when it starts like an object or an array.
    static func applicable(to text: String, type: ContentType) -> [TextTransform] {
        guard textTypes.contains(type) else { return [] }
        let probe = menuProbe(text)
        let cut = probe.utf8.count < text.utf8.count
        return allCases.filter { transform in
            guard transform != .plain || type == .richText || type == .html else { return false }
            if cut, transform == .prettyJSON || transform == .compactJSON {
                return probe.utf8.first { !isJSONWhitespace($0) }.map { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") } ?? false
            }
            return transform.apply(to: probe) != nil
        }
    }

    /// The text, or its first `menuProbeLimit` bytes, cut on a Unicode scalar. A cut drops the whitespace before it,
    /// which is mid-line in the clip and would offer "Trim whitespace" for nothing.
    private static func menuProbe(_ text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > menuProbeLimit else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: menuProbeLimit)
        while UTF8.isContinuation(utf8[end]) { utf8.formIndex(before: &end) }
        var probe = text[..<end]
        while probe.last?.isWhitespace == true { probe.removeLast() }
        return String(probe)
    }

    func label(bundle: Bundle = .main) -> String {
        switch self {
        case .plain: String(localized: "Plain text", bundle: bundle, comment: "Paste or copy as: no formatting")
        case .upper: String(localized: "UPPERCASE", bundle: bundle, comment: "Paste or copy as: all capitals")
        case .lower: String(localized: "lowercase", bundle: bundle, comment: "Paste or copy as: no capitals")
        case .title: String(localized: "Title Case", bundle: bundle, comment: "Paste or copy as: each word capitalized")
        case .trim: String(localized: "Trim whitespace", bundle: bundle,
                           comment: "Paste or copy as: spaces removed at both ends of each line, and blank lines at the ends")
        case .cleanLink: String(localized: "Clean link", bundle: bundle,
                                comment: "Paste or copy as: tracking parameters removed from links")
        case .prettyJSON: String(localized: "Pretty JSON", bundle: bundle, comment: "Paste or copy as: indented JSON")
        case .compactJSON: String(localized: "Compact JSON", bundle: bundle, comment: "Paste or copy as: JSON on one line")
        }
    }

    // MARK: Trim

    /// Spaces and tabs off both ends of every line, and blank lines off both ends of the text. Each line keeps its own
    /// terminator: `\r\n`, `\n`, `\r`, U+2028 or U+2029.
    private static func trimmed(_ text: String) -> String {
        // (content, terminator). A Character "\r\n" is one newline, so CRLF is one terminator.
        var lines: [(String, String)] = []
        var rest = text[...]
        while let end = rest.firstIndex(where: \.isNewline) {
            lines.append((rest[..<end].trimmingCharacters(in: .whitespaces), String(rest[end])))
            rest = rest[rest.index(after: end)...]
        }
        lines.append((rest.trimmingCharacters(in: .whitespaces), ""))
        guard let first = lines.firstIndex(where: { !$0.0.isEmpty }),
              let last = lines.lastIndex(where: { !$0.0.isEmpty }) else { return "" }
        return lines[first..<last].map { $0.0 + $0.1 }.joined() + lines[last].0
    }

    // MARK: Clean link

    /// Every http(s) link in the text loses its tracking parameters. The rest of the text, the other parameters in
    /// their order and encoding, and fragments stay exactly as they were.
    private static func cleanedLinks(_ text: String) -> String? {
        guard text.contains("?"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        var result = text
        // Back to front, so earlier ranges stay valid.
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let scheme = match.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: text) else { continue }
            result.replaceSubrange(range, with: cleanedLink(text[range]))
        }
        return result
    }

    private static func cleanedLink(_ link: Substring) -> String {
        let fragmentStart = link.firstIndex(of: "#") ?? link.endIndex
        guard let queryStart = link[..<fragmentStart].firstIndex(of: "?") else { return String(link) }
        let kept = link[link.index(after: queryStart)..<fragmentStart].split(separator: "&").filter { parameter in
            let name = parameter.prefix { $0 != "=" }.lowercased()
            return !trackingNames.contains(name) && !trackingPrefixes.contains { name.hasPrefix($0) }
        }
        let query = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
        return String(link[..<queryStart]) + query + link[fragmentStart...]
    }

    // MARK: JSON

    /// Valid JSON objects and arrays only. Reformats the original text rather than re-encoding the parsed value, so key
    /// order, number spelling (12345678901234567890 stays exact) and string escapes never change. Iterative, so deep
    /// nesting can't overflow the stack.
    private static func reformattedJSON(_ text: String, pretty: Bool) -> String? {
        let bytes = Array(text.utf8)
        guard let first = bytes.first(where: { !isJSONWhitespace($0) }), first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              (try? JSONSerialization.jsonObject(with: Data(bytes))) != nil else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var depth = 0, inString = false, escaped = false, i = 0
        func newline() {
            out.append(UInt8(ascii: "\n"))
            out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: depth * 2))
        }
        while i < bytes.count {
            let byte = bytes[i]
            if inString {
                out.append(byte)
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case _ where isJSONWhitespace(byte): break
                case UInt8(ascii: "\""):
                    inString = true
                    out.append(byte)
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    out.append(byte)
                    // An empty object or array stays on one line: `{}`, `[]`.
                    var next = i + 1
                    while next < bytes.count, isJSONWhitespace(bytes[next]) { next += 1 }
                    if next < bytes.count, bytes[next] == UInt8(ascii: "}") || bytes[next] == UInt8(ascii: "]") {
                        out.append(bytes[next])
                        i = next
                    } else {
                        depth += 1
                        if pretty { newline() }
                    }
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if pretty { newline() }
                    out.append(byte)
                case UInt8(ascii: ","):
                    out.append(byte)
                    if pretty { newline() }
                case UInt8(ascii: ":"):
                    out.append(byte)
                    if pretty { out.append(UInt8(ascii: " ")) }
                default:
                    out.append(byte)
                }
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

// MARK: - Edit

extension ClipboardItem {
    /// Text-like clips can be edited. A secret can't: the editor would show it, and an edit could change its detection.
    var isEditable: Bool { !isSensitive && TextTransform.textTypes.contains(contentType) }

    /// "Paste as…" / "Copy as…": none for a secret. Uppercasing a key defeats detection, and Universal Clipboard would
    /// carry the result to another device, which captures it unflagged and syncs it. A plain paste still works.
    var pasteAsTransforms: [TextTransform] {
        isSensitive ? [] : TextTransform.applicable(to: textContent ?? "", type: contentType)
    }

    /// Saves `text` as the clip's content: plain text, or a link when it is one (the capture rule), with a new
    /// `contentHash`. The sync tracker queues that as a save of the same record: an update, never a new clip.
    ///
    /// An edit that turns out to be a secret never uploads, and the clip is never flagged in place: that would also stop
    /// its delete, leaving the old text on the server for good. The server may hold it even with no system fields here
    /// (sync turned off and on again, or an upload in flight). So the clip is deleted (the tracker sends the delete; one
    /// the server never had comes back `unknownItem`), and the secret goes in a new local clip, copied now, that takes
    /// its title, pin and pinboard places; entries get new ids, since the server drops the old ones with the clip.
    ///
    /// Returns false, changing nothing, for a clip that isn't editable, empty text or the same content.
    @discardableResult
    func saveEdit(_ text: String, in context: ModelContext, now: Date = Date(),
                  protects: Bool = SecretDetector.isProtecting) -> Bool {
        guard isEditable, let edit = ClipCapture.text(text),
              edit.contentHash != contentHash || edit.contentType != contentType else { return false }
        if SecretDetector.flags(text, type: edit.contentType, protects: protects) {
            let copy = ClipboardItem(contentType: edit.contentType, rawData: edit.rawData, textContent: edit.textContent,
                                     sourceAppName: sourceAppName, sourceAppBundleId: sourceAppBundleId,
                                     contentHash: edit.contentHash)
            copy.copiedAt = now
            copy.userTitle = userTitle
            copy.isPinned = isPinned
            copy.isSensitive = true
            context.insert(copy)
            let id = self.id
            let entries = (try? context.fetch(FetchDescriptor<PinboardEntry>(
                predicate: #Predicate { $0.clipboardItem?.id == id }))) ?? []
            for entry in entries {
                if let board = entry.pinboard {
                    context.insert(PinboardEntry(clipboardItem: copy, pinboard: board, displayOrder: entry.displayOrder))
                }
                context.delete(entry)
            }
            context.delete(self)
        } else {
            contentType = edit.contentType
            rawData = edit.rawData
            textContent = edit.textContent
            contentHash = edit.contentHash
            // The preview was the old link's: the next fill fetches the new one.
            linkTitle = nil
            linkImageData = nil
            linkPreviewDone = false
            // So were the automatic pinboards and the topic: the next fills sort the new text.
            smartKinds = 0
            smartKindsVersion = 0
            topicRaw = nil
            topicDone = false
        }
        try? context.save()
        return true
    }
}
