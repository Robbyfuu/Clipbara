import XCTest

/// Review focus 5: Markdown needs two signals. A sentence with one `*` or `#` is not Markdown.
final class MarkdownDetectorTests: XCTestCase {
    func testTwoSignalsAreMarkdown() {
        for text in [
            "# Notes\n\n- milk\n- eggs",
            "# Title\nSome text\n## Section\nMore text",
            "Read **this** and [the docs](https://example.com/docs)",
            "1. Pick up the kids\n2. Buy milk",
            "```swift\nlet x = 1\n```\n\nSee **above**",
            "* one\n* two",
            "Intro paragraph.\n\n+ first\n+ second\n",
        ] {
            XCTAssertTrue(MarkdownDetector.isMarkdown(text), text)
        }
    }

    func testProseIsNotMarkdown() {
        for text in [
            "",
            "Use a * for wildcards",
            "Price: 5 * 3 = 15",
            "#hashtag #another",
            "#1 priority today",
            "I love **this** part",
            "- just one dash line",
            "See [1] and [2] in the paper",
            "Meet at 10:30, then lunch",
            "x = a * b; // comment",
            "####### seven is no heading\n####### nor this",
            "**",
        ] {
            XCTAssertFalse(MarkdownDetector.isMarkdown(text), text)
        }
    }

    /// Only the first 4 KB is read, so a huge clip costs no more than a short one.
    func testOnlyTheStartIsRead() {
        let text = String(repeating: "plain words ", count: 1_000) + "\n# One\n# Two"
        XCTAssertGreaterThan(text.utf8.count, 4096)
        XCTAssertFalse(MarkdownDetector.isMarkdown(text))
    }
}
