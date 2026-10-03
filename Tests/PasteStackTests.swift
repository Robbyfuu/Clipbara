import CoreGraphics
import XCTest

final class PasteStackTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func stack(_ order: PasteStack.Order, _ ids: [UUID]) -> PasteStack {
        var stack = PasteStack(order: order)
        ids.forEach { stack.push($0) }
        return stack
    }

    func testFifoOrder() {
        var s = stack(.fifo, [a, b, c])
        XCTAssertEqual([s.popNext(), s.popNext(), s.popNext()], [a, b, c])
    }

    func testLifoOrder() {
        var s = stack(.lifo, [a, b, c])
        XCTAssertEqual([s.popNext(), s.popNext(), s.popNext()], [c, b, a])
    }

    func testEmptyStackPassesThrough() {
        var s = PasteStack(order: .fifo)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.popNext())

        s.push(a)
        XCTAssertEqual(s.popNext(), a)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.popNext(), "a drained stack has nothing left to paste")
    }

    func testCountTracksPushPop() {
        var s = PasteStack(order: .fifo)
        XCTAssertEqual(s.count, 0)
        s.push(a)
        s.push(b)
        XCTAssertEqual(s.count, 2)
        XCTAssertFalse(s.isEmpty)
        _ = s.popNext()
        XCTAssertEqual(s.count, 1)
        _ = s.popNext()
        _ = s.popNext()
        XCTAssertEqual(s.count, 0)
    }

    /// A double ⌘C on the same selection queues it once; copying it again after another clip queues it again.
    func testRepeatedCopyIsQueuedOnce() {
        var s = stack(.fifo, [a, a, b, a])
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual([s.popNext(), s.popNext(), s.popNext()], [a, b, a])
    }

    func testOrderDefaultsToFirstCopiedFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PasteStackTests"))
        defaults.removePersistentDomain(forName: "PasteStackTests")
        XCTAssertEqual(PasteStack.Order.saved(in: defaults), .fifo)
        defaults.set(PasteStack.Order.lifo.rawValue, forKey: PasteStack.Order.defaultsKey)
        XCTAssertEqual(PasteStack.Order.saved(in: defaults), .lifo)
        defaults.removePersistentDomain(forName: "PasteStackTests")
    }

    // MARK: - Staging: a listen-only tap can't hold ⌘V, so the next clip waits on the pasteboard

    func testStageHeadOnStart() {
        for order in [PasteStack.Order.fifo, .lifo] {
            var s = PasteStack(order: order)
            XCTAssertEqual(s.stagingAfterPush(a), a, "the first copy after starting is staged (\(order))")
        }
    }

    func testFifoRestagesHeadAfterCapture() {
        var s = PasteStack(order: .fifo)
        _ = s.stagingAfterPush(a)
        XCTAssertEqual(s.stagingAfterPush(b), a, "copying b put b on the pasteboard; a goes back")
        XCTAssertEqual(s.stagingAfterPush(b), a, "a repeated copy is not queued again but still replaced a")
    }

    func testLifoNoRestage() {
        var s = PasteStack(order: .lifo)
        _ = s.stagingAfterPush(a)
        XCTAssertNil(s.stagingAfterPush(b), "b is the head and already on the pasteboard")
        XCTAssertEqual(s.count, 2)
    }

    func testPopThenStageNext() {
        var fifo = stack(.fifo, [a, b, c])
        XCTAssertEqual(fifo.stagingAfterPop(), b)
        XCTAssertEqual(fifo.count, 2)

        var lifo = stack(.lifo, [a, b, c])
        XCTAssertEqual(lifo.stagingAfterPop(), b)
        XCTAssertEqual(lifo.stagingAfterPop(), a)
    }

    func testStopsWhenEmptyAfterPop() {
        var s = stack(.fifo, [a])
        XCTAssertNil(s.stagingAfterPop(), "nothing left to stage: the stack ends")
        XCTAssertTrue(s.isEmpty)
    }

    // MARK: - The key the stack answers to

    private func keyDown(_ keyCode: CGKeyCode, _ flags: CGEventFlags, repeat isRepeat: Bool = false) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        // Real events always carry non-modifier bits such as this one.
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        return event
    }

    func testOnlyPlainCommandVIsTheStackKey() throws {
        let v: CGKeyCode = 9, c: CGKeyCode = 8
        XCTAssertTrue(PasteStack.isPasteKey(try keyDown(v, .maskCommand)))
        XCTAssertTrue(PasteStack.isPasteKey(try keyDown(v, [.maskCommand, .maskAlphaShift])), "Caps Lock is ignored")

        XCTAssertFalse(PasteStack.isPasteKey(try keyDown(v, [])))
        XCTAssertFalse(PasteStack.isPasteKey(try keyDown(v, [.maskCommand, .maskShift])), "⇧⌘V opens the panel")
        XCTAssertFalse(PasteStack.isPasteKey(try keyDown(v, [.maskCommand, .maskAlternate])))
        XCTAssertFalse(PasteStack.isPasteKey(try keyDown(v, [.maskCommand, .maskControl])))
        XCTAssertFalse(PasteStack.isPasteKey(try keyDown(c, .maskCommand)))
        XCTAssertFalse(PasteStack.isPasteKey(try keyDown(v, .maskCommand, repeat: true)), "holding ⌘V must not drain the stack")
    }
}
