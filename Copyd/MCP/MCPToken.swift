import Foundation
import os
import Security

/// The MCP access token (spec §2): 32 random bytes, base64url, kept in the Keychain as a generic password. Created on
/// first enable; Regenerate replaces it. Never logged.
enum MCPToken {
    static let service = "com.robbyfuu.copyd.mcp"
    private static let account = "access-token"
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "MCP")

    #if DEBUG
    /// `-CopydMCPToken <value>` sets the token for local testing without saving it. Never compiled in Release.
    static let debugOverrideKey = "CopydMCPToken"
    #endif

    /// `SystemRandomNumberGenerator` is cryptographically secure on Apple platforms and never fails.
    static func generate() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The saved token, or nil before the first enable.
    static func saved(service: String = service) -> String? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: debugOverrideKey), !override.isEmpty { return override }
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(service).merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
                                         as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { log.error("MCP token read failed: \(status, privacy: .public)") }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The saved token, created on first use. Nil only when the Keychain refuses it.
    static func current(service: String = service) -> String? {
        saved(service: service) ?? regenerate(service: service)
    }

    /// Replaces the saved token: clients set up with the old one must be set up again.
    @discardableResult
    static func regenerate(service: String = service) -> String? {
        SecItemDelete(query(service) as CFDictionary)
        let item = query(service).merging([kSecValueData: Data(generate().utf8), kSecAttrLabel: "Copyd MCP access token"]) { $1 }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("MCP token save failed: \(status, privacy: .public)")
            return nil
        }
        return saved(service: service)
    }

    private static func query(_ service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    // MARK: client configs (spec §4)

    static func claudeCodeCommand(port: Int, token: String) -> String {
        #"claude mcp add --transport http copyd http://127.0.0.1:\#(port)/mcp --header "Authorization: Bearer \#(token)""#
    }

    static func cursorConfig(port: Int, token: String) -> String {
        #"{"mcpServers": {"copyd": {"url": "http://127.0.0.1:\#(port)/mcp", "headers": {"Authorization": "Bearer \#(token)"}}}}"#
    }
}
