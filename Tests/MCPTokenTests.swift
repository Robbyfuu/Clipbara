import AppKit
import Security
import XCTest

/// The MCP access token (spec §2, §4): 32 random bytes in base64url, kept in the Keychain, and the client configs.
final class MCPTokenTests: XCTestCase {
    /// Never the app's own item.
    private let service = "com.robbyfuu.copyd.mcp.tests"
    /// The unhosted test process has no application identifier, so it uses the legacy keychain.
    private lazy var token = MCPToken(service: service, dataProtection: false)

    override func setUp() {
        deleteItems()
    }

    override func tearDown() {
        deleteItems()
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: MCPToken.debugOverrideKey)
        #endif
    }

    private func deleteItems() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecUseDataProtectionKeychain: true] as CFDictionary)
    }

    func testATokenIs32RandomBytesInBase64URL() throws {
        let token = MCPToken.generate()
        XCTAssertEqual(token.count, 43, "32 bytes, no padding")
        XCTAssertTrue(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        XCTAssertEqual(Data(base64Encoded: base64)?.count, 32)
        XCTAssertNotEqual(MCPToken.generate(), token)
    }

    func testTheFirstReadCreatesTheTokenAndLaterReadsReturnIt() throws {
        XCTAssertNil(try token.saved())
        let created = try token.current()
        XCTAssertEqual(try token.current(), created)
        XCTAssertEqual(try token.saved(), created)
    }

    func testRegenerateReplacesTheSavedToken() throws {
        let first = try token.current()
        let second = try token.regenerate()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try token.saved(), second)
    }

    /// Only a missing item creates a token. Here the data-protection keychain refuses the test process (no application
    /// identifier): the error comes back, and no token is created or replaced.
    func testAKeychainErrorIsSurfacedAndNothingIsCreated() throws {
        let saved = try token.current()
        let refused = MCPToken(service: service, dataProtection: true)

        XCTAssertThrowsError(try refused.current())

        XCTAssertEqual(try token.saved(), saved, "the existing token is untouched")
    }

    /// So `current()` regenerates only when there is no token, never over a token it couldn't read (a locked Keychain).
    func testOnlyAMissingItemReadsAsNoToken() throws {
        XCTAssertNil(try MCPToken.token(status: errSecItemNotFound, data: nil))
        XCTAssertEqual(try MCPToken.token(status: errSecSuccess, data: Data("abc".utf8) as CFData), "abc")
        XCTAssertThrowsError(try MCPToken.token(status: errSecInteractionNotAllowed, data: nil)) {
            XCTAssertEqual($0 as? MCPToken.KeychainError, MCPToken.KeychainError(status: errSecInteractionNotAllowed))
        }
        XCTAssertThrowsError(try MCPToken.token(status: errSecSuccess, data: nil), "success without data is an error")
    }

    #if DEBUG
    func testTheDebugOverrideWinsWithoutBeingSaved() throws {
        UserDefaults.standard.set("debug-token", forKey: MCPToken.debugOverrideKey)
        XCTAssertEqual(try token.current(), "debug-token")
        UserDefaults.standard.removeObject(forKey: MCPToken.debugOverrideKey)
        XCTAssertNil(try token.saved(), "the override never reaches the Keychain")
    }
    #endif

    // MARK: client configs

    func testClaudeCodeCommandAddsTheServerForEveryProject() {
        XCTAssertEqual(MCPToken.claudeCodeCommand(port: 39787, token: "abc"),
                       #"claude mcp add --transport http --scope user copyd http://127.0.0.1:39787/mcp --header "Authorization: Bearer abc""#)
    }

    func testCursorConfigIsValidJSON() throws {
        let config = MCPToken.cursorConfig(port: 40000, token: "abc")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let copyd = try XCTUnwrap((json["mcpServers"] as? [String: Any])?["copyd"] as? [String: Any])
        XCTAssertEqual(copyd["url"] as? String, "http://127.0.0.1:40000/mcp")
        XCTAssertEqual((copyd["headers"] as? [String: String])?["Authorization"], "Bearer abc")
    }

    /// The token and the configs stay on this Mac, and clipboard managers (Copyd included) skip them.
    @MainActor
    func testACopyIsConcealedTransientAndIgnoredByTheClassifier() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("CopydTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        MCPToken.copyConcealed("Bearer abc", to: board)

        XCTAssertEqual(board.string(forType: .string), "Bearer abc")
        let types = board.types ?? []
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        XCTAssertNil(ContentTypeClassifier().classify(board))
    }
}
