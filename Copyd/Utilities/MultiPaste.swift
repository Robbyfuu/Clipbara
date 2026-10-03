import Foundation

/// What goes between clips when several are pasted at once.
enum Separator: Codable, Equatable {
    case newline, space, comma, tab, custom(String)

    static let defaultsKey = "multiPasteSeparator"

    /// `custom` turns the typed escapes `\n` and `\t` into a new line and a tab.
    var string: String {
        switch self {
        case .newline: "\n"
        case .space: " "
        case .comma: ", "
        case .tab: "\t"
        case .custom(let raw):
            raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
        }
    }

    /// The last separator used, or a new line.
    static func saved(in defaults: UserDefaults = .standard) -> Separator {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Separator.self, from: $0) } ?? .newline
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

enum MultiPaste {
    /// Joins the text of `items` in order. Images and files can't be joined: they are skipped and counted.
    /// Nil when no text is left.
    static func join(_ items: [ClipboardItem], separator: Separator) -> (text: String, skipped: Int)? {
        let texts = items.compactMap(text(of:))
        guard !texts.isEmpty else { return nil }
        return (texts.joined(separator: separator.string), items.count - texts.count)
    }

    /// The text a clip contributes to a join, or nil when it is skipped.
    static func text(of item: ClipboardItem) -> String? {
        switch item.contentType {
        // Rich text and HTML keep their plain text; links their URL; colors their hex.
        case .plainText, .richText, .html, .url, .color, .unknown:
            item.textContent.flatMap { $0.isEmpty ? nil : $0 }
        case .image, .fileURL:
            nil
        }
    }
}

/// Cards picked with ⌘-click, ⇧-click or ⇧-arrows, in the order they were picked.
/// Holds two or more cards or none: one card left is the ordinary single selection again.
/// Each change returns the index the single selection (keyboard focus) should move to.
struct MultiSelection {
    private(set) var ids: [UUID] = []
    /// Where ⇧ ranges start, and the picks that came before it, which a range keeps.
    private var anchor: UUID?
    private var base: [UUID] = []

    /// 1-based position in the selection order.
    func number(of id: UUID) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    func items(in list: [ClipboardItem]) -> [ClipboardItem] {
        ids.compactMap { id in list.first { $0.id == id } }
    }

    /// ⌘-click. Starting a selection takes the focused card along as the first pick.
    mutating func toggle(_ index: Int, focus: Int?, in list: [UUID]) -> Int {
        guard list.indices.contains(index) else { return focus ?? index }
        let id = list[index]
        if ids.isEmpty, let focus, list.indices.contains(focus) { ids = [list[focus]] }
        if let i = ids.firstIndex(of: id) {
            ids.remove(at: i)
            anchor = nil
            return settle(ids.last.flatMap { list.firstIndex(of: $0) } ?? index, in: list)
        }
        base = ids
        ids.append(id)
        anchor = id
        return settle(index, in: list)
    }

    /// ⇧-click or ⇧-arrow: the cards from the anchor (else the focused card) to `index`, after earlier picks.
    mutating func extend(to index: Int, focus: Int?, in list: [UUID]) -> Int {
        guard list.indices.contains(index) else { return focus ?? index }
        let start: Int
        if let anchor, let i = list.firstIndex(of: anchor) {
            start = i
        } else {
            start = focus.flatMap { list.indices.contains($0) ? $0 : nil } ?? index
            anchor = list[start]
            base = ids.filter { $0 != list[start] }
        }
        let range = (start <= index ? Array(start...index) : (index...start).reversed()).map { list[$0] }
        ids = base.filter { !range.contains($0) } + range
        return settle(index, in: list)
    }

    mutating func clear() {
        ids = []
        anchor = nil
        base = []
    }

    private mutating func settle(_ focus: Int, in list: [UUID]) -> Int {
        guard ids.count < 2 else { return focus }
        let left = ids.first.flatMap { list.firstIndex(of: $0) } ?? focus
        clear()
        return left
    }
}
