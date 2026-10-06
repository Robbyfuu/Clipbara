import Foundation

/// The clip types an MCP client can filter by (spec §3). Raw values are the wire values.
enum ClipKind: String, CaseIterable, Codable, Sendable {
    case text, link, image, file, color, code
}

/// One `search_clips` result. Encoded with snake_case keys and ISO 8601 dates.
struct ClipSummary: Codable, Equatable, Sendable {
    let id: UUID
    let type: ClipKind
    /// The first 200 characters, or the OCR text or link title.
    let preview: String
    /// The source app's name.
    let app: String?
    let copiedAt: Date
    let pinned: Bool
}

/// The `get_clip` result. Images carry metadata and OCR text only, never pixels.
struct ClipDetail: Codable, Equatable, Sendable {
    let id: UUID
    let type: ClipKind
    /// The full text, capped at 100 KB; `truncated` says when it was cut.
    let text: String?
    let truncated: Bool
    let app: String?
    let copiedAt: Date
    let linkTitle: String?
    let ocrText: String?
    let fileNames: [String]
}

/// A user pinboard (`id == nil`) or a non-empty smart board (`id` is its `SmartBoard` raw value).
struct BoardSummary: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let count: Int
}

/// A tool failure the client sees word for word. Any other error reads "Copyd couldn't complete this request".
struct ToolError: Error, Equatable {
    let message: String

    static let pasting = ToolError(message: "Copyd is pasting right now; try again in a moment.")

    /// Why an agent can't write the clipboard now, or nil. Paste Stack and auto-paste write the clipboard and then post
    /// ⌘V: an agent's copy in between would be pasted instead of what the user picked.
    static func busy(pasteStackActive: Bool, autoPastePending: Bool) -> ToolError? {
        pasteStackActive || autoPastePending ? .pasting : nil
    }
}

/// What the MCP tools read and write. Implementations never return a secret, nor count one: a clip flagged
/// `isSensitive`, or one whose text or OCR text reads as a secret whatever "Protect secrets" says.
protocol ClipLibrary: Sendable {
    /// Newest first, at most `limit`.
    func search(query: String?, type: ClipKind?, board: String?, limit: Int) async throws -> [ClipSummary]
    /// `nil` for an unknown id or a secret.
    func clip(id: UUID) async throws -> ClipDetail?
    func boards() async throws -> [BoardSummary]
    /// Puts plain text on the clipboard, which Copyd then captures like any copy. Throws `ToolError.pasting` while Copyd
    /// is pasting.
    func copy(text: String) async throws
}
