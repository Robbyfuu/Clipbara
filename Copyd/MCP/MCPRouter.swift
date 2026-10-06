import Foundation

enum MCPResponse: Equatable, Sendable {
    /// 200 with this JSON-RPC response.
    case json(Data)
    /// 202 with no body: a notification, or a response from the client.
    case accepted
    /// 400 with this JSON-RPC error: a message that can't be accepted (unparseable, or no readable id).
    case invalid(Data)
}

/// JSON-RPC 2.0 in, JSON-RPC out, for the MCP methods Copyd serves (spec §2, MCP 2025-06-18): `initialize`,
/// `ping`, `tools/list` and `tools/call`. Anything else is `-32601`.
struct MCPRouter: Sendable {
    static let latestVersion = "2025-06-18"
    /// Only 2025-06-18: 2025-03-26 also allowed JSON-RPC batches, which this server doesn't accept.
    static let supportedVersions: Set<String> = [latestVersion]

    /// At most one `copy_to_clipboard` this often, and `copyBudget` within any `copyWindow`, so a runaway client can't
    /// flood the clipboard, nor push the history out through the history limit (which syncs).
    static let copyInterval: TimeInterval = 1
    static let copyBudget = 20
    static let copyWindow: TimeInterval = 600

    private let library: any ClipLibrary
    private let allowsWrite: @Sendable () -> Bool
    /// Seconds on a monotonic clock.
    private let now: @Sendable () -> TimeInterval
    private let lastCopy = LastCopy()

    /// `allowsWrite` is read on every request, so the setting applies without restarting the server.
    init(library: any ClipLibrary, allowsWrite: @escaping @Sendable () -> Bool,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.library = library
        self.allowsWrite = allowsWrite
        self.now = now
    }

    func handle(_ body: Data) async -> MCPResponse {
        guard let message = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed) else {
            return .invalid(encode(id: NSNull(), code: -32700, "Parse error"))
        }
        let unacceptable = MCPResponse.invalid(encode(id: NSNull(), code: -32600, "Invalid Request"))
        guard let object = message as? [String: Any] else { return unacceptable }
        // An id that isn't a string or an exact integer is never echoed: it can't be answered, and an infinite one
        // would raise when written back.
        let id = object["id"].flatMap(Self.validID)
        if object["id"] != nil, id == nil { return unacceptable }
        let invalidRequest = id.map { error(id: $0, code: -32600, "Invalid Request") } ?? unacceptable
        guard object["jsonrpc"] as? String == "2.0" else { return invalidRequest }
        guard let rawMethod = object["method"] else {
            let isClientResponse = id != nil && (object["result"] != nil || object["error"] != nil)
            return isClientResponse ? .accepted : invalidRequest
        }
        guard let method = rawMethod as? String else { return invalidRequest }
        guard let id else { return .accepted }

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

    /// When the copies within the last `copyWindow` were allowed, oldest first. Shared by every copy of this router.
    private final class LastCopy: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [TimeInterval] = []

        /// True, and recorded, when `copyInterval` has passed since the last allowed copy and fewer than `copyBudget`
        /// were allowed within the last `copyWindow`.
        func claim(at now: TimeInterval) -> Bool {
            lock.withLock {
                times.removeAll { now - $0 >= MCPRouter.copyWindow }
                if let last = times.last, now - last < MCPRouter.copyInterval { return false }
                guard times.count < MCPRouter.copyBudget else { return false }
                times.append(now)
                return true
            }
        }

        /// Gives back the slot claimed at `time`, for a copy that wrote nothing.
        func release(at time: TimeInterval) {
            lock.withLock {
                if let index = times.lastIndex(of: time) { times.remove(at: index) }
            }
        }
    }

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
                // Claimed before the write, so two copies at once can't both pass; a refusal (Copyd pasting) gives it back.
                let claimed = now()
                guard lastCopy.claim(at: claimed) else {
                    return failure("Too many copies; try again in a moment.")
                }
                do {
                    try await library.copy(text: text)
                } catch let refusal as ToolError {
                    lastCopy.release(at: claimed)
                    throw refusal
                }
                return try success(["copied": true])
            }
        } catch let error as ToolError {
            return failure(error.message)
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
        if let text = raw as? String { return text }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let whole = Int64(exactly: number.doubleValue)
        else { return nil }
        return whole
    }

    private func result(id: Any, _ result: [String: Any]) -> MCPResponse {
        .json(encode(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func error(id: Any, code: Int, _ message: String) -> MCPResponse {
        .json(encode(id: id, code: code, message))
    }

    private func encode(id: Any, code: Int, _ message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}
