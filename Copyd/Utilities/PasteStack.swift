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

    /// The clip the next ⌘V takes. It sits on the pasteboard ahead of time, because the stack's
    /// listen-only tap sees ⌘V but can't hold it.
    var head: UUID? { order == .fifo ? ids.first : ids.last }

    /// Queues a copy and returns the clip to put back on the pasteboard, or nil when the copy that
    /// just landed there is already the head: the first copy, and every LIFO copy. Re-staging the first
    /// one would replace the user's own pasteboard with Copyd's copy of it (one folder of a multi-folder copy).
    mutating func stagingAfterPush(_ id: UUID) -> UUID? {
        let wasEmpty = isEmpty
        push(id)
        return !wasEmpty && order == .fifo ? head : nil
    }

    /// The staged head was pasted: drops it and returns the next one to stage, or nil when the stack is done.
    mutating func stagingAfterPop() -> UUID? {
        _ = popNext()
        return head
    }

    /// The ⌘V pasted the staged head only if nothing else wrote to the pasteboard since staging.
    /// A different count means the user's own copy went in first: keep the head, don't pop.
    static func shouldPop(stagedChangeCount: Int, currentChangeCount: Int) -> Bool {
        stagedChangeCount == currentChangeCount
    }

    static let pasteKeyCode: Int64 = 9

    /// Plain ⌘V on its first press. ⇧⌘V, ⌥⌘V and the like, and key repeats, are left alone.
    /// ponytail: matches the V key position (ANSI keycode 9), like the system's own ⌘V on QWERTY;
    /// layouts that move V (plain Dvorak) would need the event's characters instead.
    static func isPasteKey(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == pasteKeyCode
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand
    }
}
