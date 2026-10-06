import XCTest

/// DNS rebinding and token checks for the local MCP server (spec §2). A web page in the user's browser must never
/// reach it: a foreign Host or Origin is 403, a missing or wrong token is 401.
final class MCPRequestGuardTests: XCTestCase {
    private let token = "s3cr3t-token_abcdefghijklmnopqrstuvwxyz0123"

    private func check(host: String? = "127.0.0.1:39787", origin: String? = nil,
                       authorization: String? = "Bearer s3cr3t-token_abcdefghijklmnopqrstuvwxyz0123") -> GuardResult {
        MCPRequestGuard.check(host: host, origin: origin, authorization: authorization, port: 39787, token: token)
    }

    func testAcceptsLoopbackHostsWithTheToken() {
        XCTAssertEqual(check(host: "127.0.0.1:39787"), .ok)
        XCTAssertEqual(check(host: "localhost:39787"), .ok)
        XCTAssertEqual(check(host: "LOCALHOST:39787"), .ok, "host names are case-insensitive")
    }

    func testRejectsAnyOtherHost() {
        for host in ["evil.com:39787", "127.0.0.1", "localhost", "127.0.0.1:39788", "localhost:39788", "0.0.0.0:39787",
                     "[::1]:39787", "127.0.0.1.evil.com:39787", "127.0.0.1:39787.evil.com", "", " 127.0.0.1:39787"] {
            XCTAssertEqual(check(host: host), .forbidden, host)
        }
        XCTAssertEqual(check(host: nil), .forbidden, "a request with no Host is refused")
    }

    func testAcceptsNoOriginOrALoopbackOrigin() {
        XCTAssertEqual(check(origin: nil), .ok, "CLI clients send no Origin")
        XCTAssertEqual(check(origin: "http://127.0.0.1:39787"), .ok)
        XCTAssertEqual(check(origin: "http://localhost:39787"), .ok)
    }

    func testRejectsAnyOtherOrigin() {
        for origin in ["https://evil.com", "http://evil.com:39787", "null", "", "http://127.0.0.1", "http://localhost:39788",
                       "https://127.0.0.1:39787", "http://127.0.0.1:39787/", "http://127.0.0.1:39787.evil.com"] {
            XCTAssertEqual(check(origin: origin), .forbidden, origin)
        }
    }

    func testRebindingIsForbiddenEvenWithTheToken() {
        XCTAssertEqual(check(host: "attacker.example:39787", origin: "http://attacker.example:39787"), .forbidden)
    }

    func testAForeignOriginIsForbiddenBeforeTheTokenIsChecked() {
        XCTAssertEqual(check(origin: "https://evil.com", authorization: nil), .forbidden)
    }

    func testRejectsAMissingOrWrongToken() {
        XCTAssertEqual(check(authorization: nil), .unauthorized)
        XCTAssertEqual(check(authorization: ""), .unauthorized)
        XCTAssertEqual(check(authorization: "Bearer"), .unauthorized)
        XCTAssertEqual(check(authorization: "Bearer "), .unauthorized)
        XCTAssertEqual(check(authorization: "Bearer wrong"), .unauthorized)
        XCTAssertEqual(check(authorization: "Basic " + token), .unauthorized)
        XCTAssertEqual(check(authorization: token), .unauthorized, "the scheme is required")
        XCTAssertEqual(check(authorization: "Bearer " + token + "x"), .unauthorized, "a longer token is wrong")
        XCTAssertEqual(check(authorization: "Bearer " + String(token.dropLast())), .unauthorized, "a prefix is wrong")
    }

    func testTheBearerSchemeIsCaseInsensitive() {
        XCTAssertEqual(check(authorization: "bearer " + token), .ok)
    }

    func testAnEmptyConfiguredTokenLetsNobodyIn() {
        XCTAssertEqual(MCPRequestGuard.check(host: "127.0.0.1:39787", origin: nil, authorization: "Bearer ", port: 39787, token: ""),
                       .unauthorized)
    }

    /// Constant time is a property of the loop (no early exit); this pins that it still answers correctly at every
    /// position and length, which an early-exit rewrite would also pass, so the review checks the loop itself.
    func testConstantTimeComparisonComparesEveryByte() {
        XCTAssertTrue(MCPRequestGuard.constantTimeEquals("abc", "abc"))
        XCTAssertTrue(MCPRequestGuard.constantTimeEquals("", ""))
        XCTAssertFalse(MCPRequestGuard.constantTimeEquals("xbc", "abc"), "differs at the first byte")
        XCTAssertFalse(MCPRequestGuard.constantTimeEquals("abx", "abc"), "differs at the last byte")
        XCTAssertFalse(MCPRequestGuard.constantTimeEquals("ab", "abc"))
        XCTAssertFalse(MCPRequestGuard.constantTimeEquals("abcd", "abc"))
        XCTAssertFalse(MCPRequestGuard.constantTimeEquals("", "abc"))
        XCTAssertFalse(MCPRequestGuard.constantTimeEquals("abc\0", "abc"), "a trailing NUL is not ignored")
    }
}
