import XCTest

final class CodeDetectorTests: XCTestCase {
    func testProseIsNotCode() {
        let prose = [
            // A paragraph: a semicolon and parentheses mid-sentence, then a sign-off.
            """
            Hi team, the meeting moved to Thursday at 3pm. Please bring the quarterly numbers (and your laptop); \
            we will review the roadmap together.

            Thanks,
            Roberto
            """,
            // A markdown list, with a heading, a nested item and a numbered item.
            """
            ## Groceries
            - Buy milk
            - Call the bank (before 5pm)
              - ask about the card
            1. Pick up the kids; then dinner
            """,
            "https://www.apple.com/shop/buy-iphone?step=select&color=blue",
            "roberto@example.com",
            "+56 9 1234 5678",
            "(555) 123-4567",
            // Notes that start with a keyword.
            "let me know if you can make it (tomorrow works too)",
            "for example: we could meet at the café, or at the office.",
            "Hola, ¿cómo estás? Te mando el documento para revisar.",
            "464501",
        ]
        for text in prose {
            XCTAssertFalse(CodeDetector.isCode(text), text)
        }
    }

    func testCodeIsCode() {
        let code = [
            "swift": "struct Point {\n    let x: Int\n    func moved() -> Point { Point(x: x + 1) }\n}",
            "js": "const total = items.reduce((sum, item) => sum + item.price, 0);\nconsole.log(total);",
            "python": "import os\n\ndef greet(name):\n    print(f\"Hello, {name}\")\n    return len(name)",
            "json": "{\"name\": \"Copyd\", \"tags\": [1, 2]}",
            "json array": "[\n  {\"id\": 1}\n]",
            "shell": "cd ~/Code/app && npm install\nexport PATH=\"$HOME/.local/bin:$PATH\"",
            "shebang": "#!/bin/zsh\necho done",
            "sql": "SELECT id, name\nFROM users\nWHERE active = 1\nORDER BY name;",
        ]
        for (language, text) in code {
            XCTAssertTrue(CodeDetector.isCode(text), language)
        }
    }

    func testReadsOnlyTheFirst2KB() {
        let prose = String(repeating: "This is a long note about the trip. ", count: 80)  // 2.9 KB on one line
        let code = String(repeating: "let x = 1;\n", count: 100)
        XCTAssertTrue(CodeDetector.isCode(code))
        XCTAssertFalse(CodeDetector.isCode(prose + "\n" + code))
    }
}
