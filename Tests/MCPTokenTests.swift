import Security
import XCTest

/// The MCP access token (spec §2, §4): 32 random bytes in base64url, kept in the Keychain, and the client configs.
final class MCPTokenTests: XCTestCase {
    /// Never the app's own item.
    private let service = "com.robbyfuu.copyd.mcp.tests"

    override func setUp() {
        deleteItem()
    }

    override func tearDown() {
        deleteItem()
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: MCPToken.debugOverrideKey)
        #endif
    }

    private func deleteItem() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
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
        XCTAssertNil(MCPToken.saved(service: service))
        let created = try XCTUnwrap(MCPToken.current(service: service))
        XCTAssertEqual(MCPToken.current(service: service), created)
        XCTAssertEqual(MCPToken.saved(service: service), created)
    }

    func testRegenerateReplacesTheSavedToken() throws {
        let first = try XCTUnwrap(MCPToken.current(service: service))
        let second = try XCTUnwrap(MCPToken.regenerate(service: service))
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(MCPToken.saved(service: service), second)
    }

    #if DEBUG
    func testTheDebugOverrideWinsWithoutBeingSaved() throws {
        UserDefaults.standard.set("debug-token", forKey: MCPToken.debugOverrideKey)
        XCTAssertEqual(MCPToken.current(service: service), "debug-token")
        UserDefaults.standard.removeObject(forKey: MCPToken.debugOverrideKey)
        XCTAssertNil(MCPToken.saved(service: service), "the override never reaches the Keychain")
    }
    #endif

    // MARK: client configs

    func testClaudeCodeCommand() {
        XCTAssertEqual(MCPToken.claudeCodeCommand(port: 39787, token: "abc"),
                       #"claude mcp add --transport http copyd http://127.0.0.1:39787/mcp --header "Authorization: Bearer abc""#)
    }

    func testCursorConfigIsValidJSON() throws {
        let config = MCPToken.cursorConfig(port: 40000, token: "abc")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let copyd = try XCTUnwrap((json["mcpServers"] as? [String: Any])?["copyd"] as? [String: Any])
        XCTAssertEqual(copyd["url"] as? String, "http://127.0.0.1:40000/mcp")
        XCTAssertEqual((copyd["headers"] as? [String: String])?["Authorization"], "Bearer abc")
    }
}
