import Foundation

/// The four MCP tools (spec §3): their `tools/list` entries and their argument validation.
enum MCPTools {
    static let defaultLimit = 20
    static let maxLimit = 50
    static let maxCopyBytes = 100 * 1024

    /// A validated `tools/call`.
    enum Call: Equatable, Sendable {
        case search(query: String?, type: ClipKind?, board: String?, limit: Int)
        /// `nil` when the id isn't a UUID, which answers "Clip not found" like an unknown one.
        case getClip(UUID?)
        case listPinboards
        case copy(String)
    }

    /// Answered as JSON-RPC `-32602` with this message.
    struct InvalidParams: Error, Equatable {
        let message: String
    }

    // MARK: validation

    /// `copy_to_clipboard` is an unknown tool unless writing is allowed, exactly as `tools/list` hides it.
    static func parse(name: String, arguments: [String: Any], allowsWrite: Bool) throws(InvalidParams) -> Call {
        switch name {
        case "search_clips":
            let rawType = try string(arguments, "type")
            var type: ClipKind?
            if let rawType {
                guard let kind = ClipKind(rawValue: rawType) else {
                    throw InvalidParams(message: "type must be one of: " + ClipKind.allCases.map(\.rawValue).joined(separator: ", "))
                }
                type = kind
            }
            let limit = try integer(arguments, "limit") ?? defaultLimit
            return .search(query: try string(arguments, "query"), type: type, board: try string(arguments, "board"),
                           limit: min(max(limit, 1), maxLimit))
        case "get_clip":
            guard let id = arguments["id"] as? String else { throw InvalidParams(message: "id must be a clip id string") }
            return .getClip(UUID(uuidString: id))
        case "list_pinboards":
            return .listPinboards
        case "copy_to_clipboard" where allowsWrite:
            guard let text = arguments["text"] as? String else { throw InvalidParams(message: "text must be a string") }
            guard text.utf8.count <= maxCopyBytes else { throw InvalidParams(message: "text must be at most 100 KB") }
            return .copy(text)
        default:
            throw InvalidParams(message: "Unknown tool: \(name)")
        }
    }

    /// An optional string argument; blank counts as absent.
    private static func string(_ arguments: [String: Any], _ key: String) throws(InvalidParams) -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw InvalidParams(message: "\(key) must be a string") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An optional whole-number argument. JSON booleans bridge to NSNumber too, so they are refused explicitly.
    private static func integer(_ arguments: [String: Any], _ key: String) throws(InvalidParams) -> Int? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let whole = Int(exactly: number.doubleValue)
        else { throw InvalidParams(message: "\(key) must be a whole number") }
        return whole
    }

    // MARK: tools/list

    static func definitions(allowsWrite: Bool) -> [[String: Any]] {
        var tools = [searchClips, getClip, listPinboards]
        if allowsWrite { tools.append(copyToClipboard) }
        return tools
    }

    private static let kinds = ClipKind.allCases.map(\.rawValue)

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func stringSchema(_ description: String? = nil) -> [String: Any] {
        description.map { ["type": "string", "description": $0] } ?? ["type": "string"]
    }

    private static var searchClips: [String: Any] {
        let summary = object([
            "id": stringSchema(), "type": ["type": "string", "enum": kinds], "preview": stringSchema(), "app": stringSchema(),
            "copied_at": ["type": "string", "format": "date-time"], "pinned": ["type": "boolean"],
        ], required: ["id", "type", "preview", "copied_at", "pinned"])
        return [
            "name": "search_clips",
            "description": "Search the user's Copyd clipboard history, newest first. Matches text, text recognized in images, "
                + "link titles and file names, ignoring case and accents. Secrets are never returned.",
            "inputSchema": object([
                "query": stringSchema("Words to look for. Omit to list the newest clips."),
                "type": ["type": "string", "enum": kinds, "description": "Only clips of this type."],
                "board": stringSchema("A pinboard name or a smart board id from list_pinboards, such as links or work."),
                "limit": ["type": "integer", "minimum": 1, "maximum": maxLimit, "default": defaultLimit],
            ]),
            "outputSchema": object(["clips": ["type": "array", "items": summary]], required: ["clips"]),
        ]
    }

    private static var getClip: [String: Any] {
        [
            "name": "get_clip",
            "description": "Read one clip by its id from search_clips: the full text (capped at 100 KB), the link title, "
                + "the text recognized in an image and file names. Images never return pixels.",
            "inputSchema": object(["id": stringSchema("The clip id from search_clips.")], required: ["id"]),
            "outputSchema": object([
                "id": stringSchema(), "type": ["type": "string", "enum": kinds], "text": stringSchema(), "truncated": ["type": "boolean"],
                "app": stringSchema(), "copied_at": ["type": "string", "format": "date-time"], "link_title": stringSchema(),
                "ocr_text": stringSchema(), "file_names": ["type": "array", "items": stringSchema()],
            ], required: ["id", "type", "truncated", "copied_at", "file_names"]),
        ]
    }

    private static var listPinboards: [String: Any] {
        let count: [String: Any] = ["type": "integer"]
        return [
            "name": "list_pinboards",
            "description": "List the user's pinboards and the non-empty automatic smart boards, with their clip counts. "
                + "Pass a pinboard name or a smart board id to search_clips as board.",
            "inputSchema": object([:]),
            "outputSchema": object([
                "pinboards": ["type": "array", "items": object(["name": stringSchema(), "count": count], required: ["name", "count"])],
                "smart_boards": ["type": "array",
                                 "items": object(["id": stringSchema(), "name": stringSchema(), "count": count], required: ["id", "name", "count"])],
            ], required: ["pinboards", "smart_boards"]),
        ]
    }

    private static var copyToClipboard: [String: Any] {
        [
            "name": "copy_to_clipboard",
            "description": "Put plain text on the Mac's clipboard, where Copyd saves it like any copy. At most 100 KB.",
            "inputSchema": object(["text": stringSchema("The text to copy.")], required: ["text"]),
            "outputSchema": object(["copied": ["type": "boolean"]], required: ["copied"]),
        ]
    }
}
