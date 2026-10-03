import XCTest

final class PasteActionTests: XCTestCase {
    func testTextUnderLimitInserts() {
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: "hi"), .insert("hi"))
    }

    func testTextAtExactlyLimitInserts() {
        let t = String(repeating: "a", count: PasteAction.insertByteLimit)
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: t), .insert(t))
    }

    func testTextOverLimitCopies() {
        let t = String(repeating: "a", count: PasteAction.insertByteLimit + 1)
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: t), .copyToPasteboard)
    }

    func testMultibyteTextUsesByteCount() {
        let ok = String(repeating: "é", count: 20_000)
        let big = String(repeating: "é", count: 30_000)
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: ok), .insert(ok))
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: big), .copyToPasteboard)
    }

    func testImageAlwaysCopies() {
        XCTAssertEqual(PasteAction.decide(contentType: .image, text: "x"), .copyToPasteboard)
    }

    func testColorInsertsHex() {
        XCTAssertEqual(PasteAction.decide(contentType: .color, text: "#FF0000"), .insert("#FF0000"))
    }

    func testNilTextCopies() {
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: nil), .copyToPasteboard)
        XCTAssertEqual(PasteAction.decide(contentType: .plainText, text: ""), .copyToPasteboard)
    }
}
