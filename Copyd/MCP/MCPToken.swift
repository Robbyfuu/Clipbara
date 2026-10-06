import AppKit
import os
import Security

/// The MCP access token (spec §2): 32 random bytes, base64url, kept in the Keychain as a generic password. Created on
/// first enable; Regenerate replaces it. Never logged.
struct MCPToken: Sendable {
    /// The app's token: in the data-protection keychain, readable after first unlock, never moved to another device.
    static let app = MCPToken(service: "com.robbyfuu.copyd.mcp", dataProtection: true)

    /// A Keychain call failed with this status; not finding the item is not an error.
    struct KeychainError: Error, Equatable {
        let status: OSStatus
    }

    let service: String
    /// False only for the unhosted test process, which has no application identifier for the data-protection keychain.
    let dataProtection: Bool

    private static let account = "access-token"
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "MCP")

    #if DEBUG
    /// `-CopydMCPToken <value>` sets the token for local testing without saving it. Never compiled in Release.
    static let debugOverrideKey = "CopydMCPToken"

    /// The value after `-CopydMCPToken` in the launch arguments. Never UserDefaults: a value saved there with
    /// `defaults write` would outlive the launch and pin a known token.
    static func debugOverride(in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let flag = arguments.firstIndex(of: "-" + debugOverrideKey), flag + 1 < arguments.count,
              !arguments[flag + 1].isEmpty else { return nil }
        return arguments[flag + 1]
    }
    #endif

    /// `SystemRandomNumberGenerator` is cryptographically secure on Apple platforms and never fails.
    static func generate() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The saved token, or nil before the first enable. Throws on any other Keychain error.
    func saved() throws(KeychainError) -> String? {
        #if DEBUG
        if let override = Self.debugOverride() { return override }
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
                                         as CFDictionary, &result)
        if status != errSecSuccess, status != errSecItemNotFound { _ = failure("read", status) }
        return try Self.token(status: status, data: result)
    }

    /// A Keychain read's token: nil only when there is none; any other failure is an error.
    static func token(status: OSStatus, data: CFTypeRef?) throws(KeychainError) -> String? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = data as? Data else { throw KeychainError(status: errSecDecode) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The saved token, created only when there is none: a Keychain error is thrown, and nothing is deleted.
    func current() throws(KeychainError) -> String {
        if let token = try saved() { return token }
        return try regenerate()
    }

    /// Replaces the saved token: clients set up with the old one must be set up again.
    @discardableResult
    func regenerate() throws(KeychainError) -> String {
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw failure("delete", deleted) }
        var item = query.merging([kSecValueData: Data(Self.generate().utf8), kSecAttrLabel: "Copyd MCP access token"]) { $1 }
        if dataProtection { item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure("save", added) }
        guard let token = try saved() else { throw failure("read", errSecItemNotFound) }
        return token
    }

    private var query: [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: Self.account]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    private func failure(_ action: StaticString, _ status: OSStatus) -> KeychainError {
        Self.log.error("MCP token \(action, privacy: .public) failed: \(status, privacy: .public)")
        return KeychainError(status: status)
    }

    // MARK: copies (spec §4)

    static func claudeCodeCommand(port: Int, token: String) -> String {
        #"claude mcp add --transport http --scope user copyd http://127.0.0.1:\#(port)/mcp --header "Authorization: Bearer \#(token)""#
    }

    static func cursorConfig(port: Int, token: String) -> String {
        #"{"mcpServers": {"copyd": {"url": "http://127.0.0.1:\#(port)/mcp", "headers": {"Authorization": "Bearer \#(token)"}}}}"#
    }

    /// Writes text holding the token: never to Universal Clipboard, and marked concealed and transient, so clipboard
    /// managers (Copyd's own classifier included) skip it.
    @MainActor
    static func copyConcealed(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }
}
