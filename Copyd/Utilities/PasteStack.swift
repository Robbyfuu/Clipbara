import CoreGraphics
import Foundation

/// The clips queued by Paste Stack, by id. Each ⌘V takes the next one.
struct PasteStack {
    enum Order: String {
        /// First copied, first pasted: the order you copied in.
        case fifo
        /// Last copied, first pasted.
        case lifo

        static let defaultsKey = "pasteStackOrder"

        static func saved(in defaults: UserDefaults = .standard) -> Order {
            defaults.string(forKey: defaultsKey).flatMap(Order.init) ?? .fifo
        }
    }

    let order: Order
    /// In copy order; `order` decides which end `popNext` takes.
    private var ids: [UUID] = []

    init(order: Order) { self.order = order }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    /// The same clip twice in a row is queued once, so a double ⌘C does not paste twice.
    mutating func push(_ id: UUID) {
        guard ids.last != id else { return }
        ids.append(id)
    }

    mutating func popNext() -> UUID? {
        guard !ids.isEmpty else { return nil }
        return order == .fifo ? ids.removeFirst() : ids.removeLast()
    }

    /// Plain ⌘V on its first press. ⇧⌘V, ⌥⌘V and the like, and key repeats, are left alone.
    /// ponytail: matches the V key position (ANSI keycode 9), like the system's own ⌘V on QWERTY;
    /// layouts that move V (plain Dvorak) would need the event's characters instead.
    static func isPasteKey(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == 9
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand
    }
}
