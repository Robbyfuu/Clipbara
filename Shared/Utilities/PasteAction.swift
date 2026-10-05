/// Decides whether the keyboard inserts text directly or leaves the clip on the pasteboard.
enum PasteAction: Equatable {
    case insert(String), copyToPasteboard
    static let insertByteLimit = 51_200

    static func decide(contentType: ContentType, text: String?) -> PasteAction {
        guard contentType != .image, let text, !text.isEmpty else { return .copyToPasteboard }
        if contentType == .color { return .insert(text) }
        return text.utf8.count <= insertByteLimit ? .insert(text) : .copyToPasteboard
    }
}
