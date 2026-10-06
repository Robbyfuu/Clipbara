import Foundation

enum MCPResponse: Equatable, Sendable {
    /// 200 with this JSON-RPC response.
    case json(Data)
    /// 202 with no body: a notification, or a response from the client.
    case accepted
}

/// JSON-RPC 2.0 in, JSON-RPC out, for the MCP methods Copyd serves (spec §2, MCP 2025-06-18): `initialize`,
/// `ping`, `tools/list` and `tools/call`. Anything else is `-32601`.
struct MCPRouter: Sendable {
    static let latestVersion = "2025-06-18"
    /// Streamable HTTP exists from 2025-03-26; both share the shapes served here.
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26"]

    private let library: any ClipLibrary
    private let allowsWrite: @Sendable () -> Bool

    /// `allowsWrite` is read on every request, so the setting applies without restarting the server.
    init(library: any ClipLibrary, allowsWrite: @escaping @Sendable () -> Bool) {
        self.library = library
        self.allowsWrite = allowsWrite
    }

    func handle(_ body: Data) async -> MCPResponse {
        guard let message = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed) else {
            return error(id: NSNull(), code: -32700, "Parse error")
        }
        guard let object = message as? [String: Any], object["jsonrpc"] as? String == "2.0" else {
            return error(id: NSNull(), code: -32600, "Invalid Request")
        }
        guard let rawMethod = object["method"] else {
            let isClientResponse = object["id"] != nil && (object["result"] != nil || object["error"] != nil)
            return isClientResponse ? .accepted : error(id: NSNull(), code: -32600, "Invalid Request")
        }
        guard let method = rawMethod as? String else { return error(id: NSNull(), code: -32600, "Invalid Request") }
        guard let rawID = object["id"] else { return .accepted }
        guard let id = Self.validID(rawID) else { return error(id: NSNull(), code: -32600, "Invalid Request") }

        var params: [String: Any] = [:]
        if let raw = object["params"], !(raw is NSNull) {
            guard let dictionary = raw as? [String: Any] else { return error(id: id, code: -32602, "params must be an object") }
            params = dictionary
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.latestVersion
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            return result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "copyd", "title": "Copyd", "version": appVersion],
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": MCPTools.definitions(allowsWrite: allowsWrite())])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id: id, code: -32602, "params.name must be a tool name") }
            var arguments: [String: Any] = [:]
            if let raw = params["arguments"], !(raw is NSNull) {
                guard let dictionary = raw as? [String: Any] else { return error(id: id, code: -32602, "arguments must be an object") }
                arguments = dictionary
            }
            do {
                let call = try MCPTools.parse(name: name, arguments: arguments, allowsWrite: allowsWrite())
                return result(id: id, await run(call))
            } catch {
                return self.error(id: id, code: -32602, error.message)
            }
        default:
            return error(id: id, code: -32601, "Method not found")
        }
    }

    // MARK: tools

    private struct Boards: Encodable {
        let pinboards: [BoardSummary]
        let smartBoards: [BoardSummary]
    }

    /// A tool result: the object as JSON text plus `structuredContent`, or `isError` with a message.
    private func run(_ call: MCPTools.Call) async -> [String: Any] {
        do {
            switch call {
            case let .search(query, type, board, limit):
                return try success(["clips": try await library.search(query: query, type: type, board: board, limit: limit)])
            case .getClip(let id):
                guard let id, let detail = try await library.clip(id: id) else { return failure("Clip not found") }
                return try success(detail)
            case .listPinboards:
                let boards = try await library.boards()
                return try success(Boards(pinboards: boards.filter { $0.id == nil }, smartBoards: boards.filter { $0.id != nil }))
            case .copy(let text):
                try await library.copy(text: text)
                return try success(["copied": true])
            }
        } catch {
            return failure("Copyd couldn't complete this request. Try again.")
        }
    }

    private func success(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": try JSONSerialization.jsonObject(with: data),
            "isError": false,
        ]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: JSON-RPC

    /// MCP ids are strings or integers, never null; JSON booleans bridge to NSNumber, so they are refused explicitly.
    private static func validID(_ raw: Any) -> Any? {
        if raw is String { return raw }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number }
        return nil
    }

    private func result(id: Any, _ result: [String: Any]) -> MCPResponse {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(id: Any, code: Int, _ message: String) -> MCPResponse {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> MCPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        return .json(data)
    }
}
