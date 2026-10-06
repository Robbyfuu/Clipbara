import Foundation

enum GuardResult: Equatable, Sendable {
    case ok
    /// 403: a foreign `Host` or `Origin` (DNS rebinding, a web page).
    case forbidden
    /// 401: a missing or wrong bearer token.
    case unauthorized
}

/// The MCP server's per-request checks (spec §2). Host and Origin come first, so a rebinding page is refused before
/// its token is even looked at.
enum MCPRequestGuard {
    static func check(host: String?, origin: String?, authorization: String?, port: UInt16, token: String) -> GuardResult {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host, hosts.contains(host.lowercased()) else { return .forbidden }
        if let origin, !hosts.map({ "http://" + $0 }).contains(origin.lowercased()) { return .forbidden }

        guard !token.isEmpty, let authorization,
              let space = authorization.firstIndex(of: " "),
              authorization[..<space].lowercased() == "bearer"
        else { return .unauthorized }
        let presented = String(authorization[authorization.index(after: space)...])
        return constantTimeEquals(presented, token) ? .ok : .unauthorized
    }

    /// Compares every byte whatever the first mismatch, so the time taken never tells how much of a guess was right.
    /// Only the length can leak, and the token's length is fixed and public.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            difference |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return difference == 0
    }
}
