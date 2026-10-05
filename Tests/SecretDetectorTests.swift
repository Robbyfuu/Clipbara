import XCTest

/// Fake secrets, built from pieces so secret scanners never read a whole key in this file.
enum FakeSecret {
    static let aws = "AKIA" + "IOSFODNN7EXAMPLE"  // AWS's documented example key
    static let github = "gh" + "p_" + String(repeating: "aB3d", count: 9)
    static let githubOAuth = "gh" + "o_" + String(repeating: "Zy9x", count: 9)
    static let githubPAT = "github" + "_pat_" + "11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV"
    static let stripe = "sk" + "_live_" + "4eC39HqLyjWDarjtT1zdp7dc"
    static let stripeRestricted = "rk" + "_live_" + "51H8x2CJ3k9Lmn0PqRsTuVwX"
    static let slack = "xox" + "b-" + "123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"
    static let openAI = "sk" + "-proj-" + "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z"
    static let anthropic = "sk" + "-ant-" + "api03-" + "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
    static let google = "AI" + "za" + "SyA-1234567890abcdefghijklmnopqrstu"
    static let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0"
        + "." + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    static let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA3Tz2mr7SZiAMfQyuvBjM9Oi\nZ1BjP5CE8Wt3c4nHq0f4f3Qx\n"
        + "-----END RSA PRIVATE KEY-----\n"
}

final class SecretDetectorTests: XCTestCase {
    private func kind(_ text: String) -> SecretKind? { SecretDetector.kind(of: text) }

    // MARK: Patterns

    func testAWSAccessKey() {
        XCTAssertEqual(kind(FakeSecret.aws), .apiKey)
        XCTAssertEqual(kind("AS" + "IA" + "IOSFODNN7EXAMPLE"), .apiKey, "a temporary STS key")
        XCTAssertNil(kind("AKIA" + "IOSFODNN7EXAMPL"), "15 characters after AKIA")
        XCTAssertNil(kind("akia" + "iosfodnn7example"), "lowercase")
    }

    func testGitHubTokens() {
        XCTAssertEqual(kind(FakeSecret.github), .token)
        XCTAssertEqual(kind(FakeSecret.githubOAuth), .token)
        XCTAssertEqual(kind(FakeSecret.githubPAT), .token)
        for letter in ["u", "s", "r"] {
            XCTAssertEqual(kind("gh" + letter + "_" + String(repeating: "aB3d", count: 9)), .token, "gh\(letter)_")
        }
        XCTAssertNil(kind("gh" + "x_" + String(repeating: "aB3d", count: 9)), "x is not a GitHub token type")
        XCTAssertNil(kind("gh" + "p_" + "short123"))
        XCTAssertNil(kind("github" + "_pat_" + "abc"))
    }

    func testStripeLiveKeys() {
        XCTAssertEqual(kind(FakeSecret.stripe), .apiKey)
        XCTAssertEqual(kind(FakeSecret.stripeRestricted), .apiKey)
        XCTAssertNil(kind("sk" + "_test_" + "4eC39HqLyjWDarjtT1zdp7dc"), "test keys are not live")
        XCTAssertNil(kind("sk" + "_live_" + "abc"))
    }

    func testSlackTokens() {
        XCTAssertEqual(kind(FakeSecret.slack), .token)
        for letter in ["a", "p", "r", "s"] {
            XCTAssertEqual(kind("xox" + letter + "-" + "123456789012-AbCdEfGhIj"), .token, letter)
        }
        XCTAssertNil(kind("xox" + "z-" + "123456789012-AbCdEfGhIj"), "z is not a Slack token type")
        XCTAssertNil(kind("xox" + "b-1"))
    }

    func testOpenAIKeys() {
        XCTAssertEqual(kind(FakeSecret.openAI), .apiKey)
        XCTAssertEqual(kind("sk-" + "T3BlbkFJ" + String(repeating: "x9Y", count: 10)), .apiKey)
        XCTAssertNil(kind("sk-" + "Ab3dEf6hIj9kLm2nOp5qRs8tUv"), "under 32 characters")
        XCTAssertNil(kind("sk-learn-model-selection-cross-validation"), "a hyphenated name, not a key")
    }

    func testAnthropicKeys() {
        XCTAssertEqual(kind(FakeSecret.anthropic), .apiKey)
        XCTAssertNil(kind("sk" + "-ant-" + "abc"))
    }

    func testGoogleAPIKeys() {
        XCTAssertEqual(FakeSecret.google.count, 39)
        XCTAssertEqual(kind(FakeSecret.google), .apiKey)
        XCTAssertNil(kind(String(FakeSecret.google.dropLast())), "38 characters")
        XCTAssertNil(kind(FakeSecret.google + "x"), "40 characters")
    }

    func testJWT() {
        XCTAssertEqual(kind(FakeSecret.jwt), .token)
        XCTAssertNil(kind("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), "one segment is base64 JSON, not a token")
        XCTAssertNil(kind("eyJhbGciOiJIUzI1NiJ9.notjson.sig"))
    }

    func testPrivateKeys() {
        XCTAssertEqual(kind(FakeSecret.pem), .privateKey)
        XCTAssertEqual(kind("-----BEGIN " + "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n"), .privateKey)
        XCTAssertEqual(kind("-----BEGIN " + "PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEI\n"), .privateKey)
        XCTAssertEqual(kind("-----BEGIN " + "ENCRYPTED PRIVATE KEY-----\nMIIFHDBOBgkqhkiG9w0B\n"), .privateKey)
        XCTAssertEqual(kind("Deploy key for staging:\n" + FakeSecret.pem), .privateKey, "a label line before the key")
        XCTAssertEqual(kind("-----BEGIN " + "PGP PRIVATE KEY BLOCK-----\n\nlQOYBGU5n3kBCAC7\n=Xq2T\n"
                            + "-----END PGP PRIVATE KEY BLOCK-----"), .privateKey)
        XCTAssertNil(kind("-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQENBGU5n3kBCAC7\n-----END PGP PUBLIC KEY BLOCK-----"))
        XCTAssertNil(kind("-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEF\n-----END PUBLIC KEY-----"))
        XCTAssertNil(kind("-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIE\n-----END CERTIFICATE-----"))
    }

    /// The common ways a key gets copied: alone, quoted, as an `.env` line, or as a header value.
    func testKeyInAnAssignmentOrQuotes() {
        XCTAssertEqual(kind("  " + FakeSecret.stripe + "\n"), .apiKey, "surrounding whitespace")
        XCTAssertEqual(kind("\"" + FakeSecret.stripe + "\""), .apiKey)
        XCTAssertEqual(kind("OPENAI_API_KEY=" + FakeSecret.openAI), .apiKey)
        XCTAssertEqual(kind("export AWS_ACCESS_KEY_ID=" + FakeSecret.aws), .apiKey)
        XCTAssertEqual(kind("api_key: '" + FakeSecret.google + "'"), .apiKey)
        XCTAssertEqual(kind("Authorization: Bearer " + FakeSecret.jwt), .token)
    }

    /// A key copied out of code, a config file or a shell: syntax around it, but no prose.
    func testKeyWithCodeSyntax() {
        XCTAssertEqual(kind("\"k\": \"" + FakeSecret.stripe + "\","), .apiKey, "a JSON member")
        XCTAssertEqual(kind("const K = \"" + FakeSecret.stripe + "\";"), .apiKey)
        XCTAssertEqual(kind("let token = '" + FakeSecret.github + "'"), .token)
        XCTAssertEqual(kind("var key = \"" + FakeSecret.openAI + "\""), .apiKey)
        XCTAssertEqual(kind(FakeSecret.aws + ";"), .apiKey, "a trailing semicolon")
        XCTAssertEqual(kind("curl -H \"Authorization: Bearer " + FakeSecret.jwt + "\""), .token)
    }

    /// A `.env` file copied whole: every line that is not blank or a `#` comment is `NAME=value`, and one holds a key.
    func testEnvBlock() {
        let env = "# Payments\nNODE_ENV=production\nSTRIPE_SECRET_KEY=" + FakeSecret.stripe + "\n\nexport PORT=3000\n"
        XCTAssertEqual(kind(env), .apiKey)
        XCTAssertEqual(kind("GITHUB_TOKEN=" + FakeSecret.github + "\nOPENAI_API_KEY=" + FakeSecret.openAI), .token,
                       "the first key decides")
        XCTAssertNil(kind("NODE_ENV=production\nPORT=3000"), "no line holds a key")
        XCTAssertNil(kind("Staging keys:\nSTRIPE_SECRET_KEY=" + FakeSecret.stripe), "a prose line")
    }

    /// A key inside prose is left alone: masking and deleting a whole note over one key would lose the note.
    func testKeyInsideProseIsNotFlagged() {
        XCTAssertNil(kind("Here is the key for staging: " + FakeSecret.stripe + " (rotate it Monday)"))
        XCTAssertNil(kind("Set const K = \"" + FakeSecret.stripe + "\"; then restart the server"))
        XCTAssertNil(kind("Run curl -H \"Authorization: Bearer " + FakeSecret.jwt + "\" against staging"))
        XCTAssertNil(kind("The token " + FakeSecret.github + ";"))
    }

    // MARK: Cards

    func testLuhn() {
        XCTAssertTrue(SecretDetector.passesLuhn("79927398713"))
        XCTAssertTrue(SecretDetector.passesLuhn("4242424242424242"))
        XCTAssertFalse(SecretDetector.passesLuhn("4242424242424241"))
        XCTAssertFalse(SecretDetector.passesLuhn("79927398710"))
    }

    func testCardNumbers() {
        for card in ["4242 4242 4242 4242", "4111-1111-1111-1111", "4111111111111111", "5555555555554444",
                     "3782 822463 10005", "6011 0000 0000 0004", "4012888888881881",
                     "2223003122003222",  // Mastercard 2-series
                     "30569309025904",  // Diners, 14 digits
                     "3530111333300000",  // JCB
                     "4111111111111111110"] {  // Visa, 19 digits
            XCTAssertEqual(kind(card), .card, card)
        }
        // Each passes Luhn, at a length its network never issues.
        XCTAssertNil(kind("4222222222222"), "13-digit Visa")
        XCTAssertNil(kind("411111111111116"), "15-digit Visa")
        XCTAssertNil(kind("3400000000000000"), "16-digit Amex")
        XCTAssertNil(kind("2000000000000006"), "20 is no network's prefix")
        XCTAssertNil(kind("4242 4242 4242 4241"), "fails Luhn")
        XCTAssertNil(kind("4242-4242 4242 4242"), "mixed separators")
        XCTAssertNil(kind("424242424242"), "12 digits")
        XCTAssertNil(kind("42424242424242424242"), "20 digits")
        XCTAssertNil(kind("Card: 4242 4242 4242 4242 exp 12/30"), "inside other text")
    }

    /// Review focus 2: everyday text must never be taken for a secret, or it would be masked and deleted.
    func testCommonStringsAreNotSecrets() {
        let everyday = [
            "https://www.amazon.com/s?k=usb+c+cable&crid=2M096C61O4MLT&sprefix=usb+c+cable%2Caps%2C283&ref=nb_sb_noss_1",
            "https://www.google.com/maps/place/Santiago/@-33.4724228,-70.7699154,11z/data=!3m1!4b1!4m6!3m5!1s0x9662c5410425af2f:0x8475d53c400f0931",
            "https://www.airbnb.cl/rooms/39393838?check_in=2026-10-07&adults=3&source_impression_id=p3_1696411234_AbCdEfGhIjKlMnOp",
            "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "e621e1f8-c36c-495a-93fc-0c247a3e6e5f",
            "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3",
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
            "112-4567890-1234562",  // Amazon order, passes Luhn
            "402-4567890-1234561",  // same layout, passes Luhn
            "Order #4501234563",
            "1696411234564",  // a timestamp in milliseconds, passes Luhn
            "1234567812345670",  // passes Luhn, but no card starts with 1
            "356938035643809",  // an iPhone IMEI, passes Luhn
            "4006381000093",  // an EAN-13 barcode, passes Luhn
            "+56 9 1234 5678",
            "12.345.678-5",
            "1Z999AA10123456784",
            "GB82 WEST 1234 5698 7654 32",
            "sk-learn",
            "Hello, world",
            "",
        ]
        for text in everyday {
            XCTAssertNil(kind(text), text)
        }
    }

    // MARK: Masking

    func testMaskShowsTheLabelAndLastFour() {
        XCTAssertEqual(SecretDetector.mask(FakeSecret.stripe, kind: .apiKey), "API key •••• p7dc")
        XCTAssertEqual(SecretDetector.mask("4242 4242 4242 4242", kind: .card), "Card •••• 4242")
        XCTAssertEqual(SecretDetector.mask(FakeSecret.jwt, kind: .token), "Token •••• sR8U")
        XCTAssertEqual(SecretDetector.mask("\"" + FakeSecret.stripe + "\"\n", kind: .apiKey), "API key •••• p7dc",
                       "quotes and whitespace are not part of the key")
    }

    func testPrivateKeyMaskUsesTheKeyBodyNotTheEndLine() {
        XCTAssertEqual(SecretDetector.mask(FakeSecret.pem, kind: .privateKey), "Private key •••• f3Qx")
    }

    /// The test bundle carries the iPhone's catalog; its `es.lproj` picks Spanish whatever this Mac's language is.
    func testSpanishLabels() throws {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(SecretDetector.mask(FakeSecret.stripe, kind: .apiKey, bundle: es), "Clave de API •••• p7dc")
        XCTAssertEqual(SecretDetector.mask(FakeSecret.jwt, kind: .token, bundle: es), "Token •••• sR8U")
        XCTAssertEqual(SecretDetector.mask(FakeSecret.pem, kind: .privateKey, bundle: es), "Clave privada •••• f3Qx")
        XCTAssertEqual(SecretDetector.mask("4242 4242 4242 4242", kind: .card, bundle: es), "Tarjeta •••• 4242")
    }

    // MARK: Capture rule

    func testCaptureFlagsTextSecretsOnlyWhileProtecting() {
        XCTAssertTrue(SecretDetector.flags(FakeSecret.stripe, type: .plainText, protects: true))
        XCTAssertTrue(SecretDetector.flags(FakeSecret.pem, type: .richText, protects: true))
        XCTAssertFalse(SecretDetector.flags(FakeSecret.stripe, type: .plainText, protects: false), "Protect secrets is off")
        XCTAssertFalse(SecretDetector.flags("hello", type: .plainText, protects: true))
        XCTAssertFalse(SecretDetector.flags(nil, type: .image, protects: true))
        XCTAssertFalse(SecretDetector.flags(FakeSecret.stripe, type: .files, protects: true), "a file name, not the copy")
        XCTAssertFalse(SecretDetector.flags(FakeSecret.stripe, type: .fileURL, protects: true))
    }
}

final class SecretSweeperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    func testExpiresOnlySecretsPastTheirTime() {
        let clips = [
            (id: id(1), copiedAt: now.addingTimeInterval(-360), isSensitive: true, isKept: false),
            (id: id(2), copiedAt: now.addingTimeInterval(-240), isSensitive: true, isKept: false),
            (id: id(3), copiedAt: now.addingTimeInterval(-3_600), isSensitive: false, isKept: false),
            (id: id(4), copiedAt: now.addingTimeInterval(-300), isSensitive: true, isKept: false),
            (id: id(5), copiedAt: now.addingTimeInterval(60), isSensitive: true, isKept: false),  // another device's clock
        ]
        XCTAssertEqual(SecretSweeper.expired(clips: clips, now: now, after: 300), [id(1), id(4)])
    }

    /// A pinned secret, or one on a pinboard, is kept: it stays local and masked, and is never deleted.
    func testKeptSecretsNeverExpire() {
        let clips = [
            (id: id(1), copiedAt: now.addingTimeInterval(-86_400), isSensitive: true, isKept: true),
            (id: id(2), copiedAt: now.addingTimeInterval(-86_400), isSensitive: true, isKept: false),
        ]
        XCTAssertEqual(SecretSweeper.expired(clips: clips, now: now, after: 300), [id(2)])
    }

    func testNeverKeepsEverySecret() {
        let clips = [(id: id(1), copiedAt: now.addingTimeInterval(-86_400), isSensitive: true, isKept: false)]
        XCTAssertEqual(SecretSweeper.expired(clips: clips, now: now, after: nil), [])
    }

    func testSettingDefaultsToFiveMinutesAndZeroIsNever() {
        let defaults = SecretDetector.settings
        let key = SecretSweeper.deleteAfterDefaultsKey
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(SecretSweeper.deleteAfter, 300)
        defaults.set(15, forKey: key)
        XCTAssertEqual(SecretSweeper.deleteAfter, 900)
        defaults.set(0, forKey: key)
        XCTAssertNil(SecretSweeper.deleteAfter)
        XCTAssertEqual(SecretSweeper.choices, [1, 5, 15, 60, 0])
    }
}
