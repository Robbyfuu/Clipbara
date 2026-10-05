import Foundation

enum ContentType: String, Codable, CaseIterable, Sendable {
    case plainText
    case richText
    case html
    case image
    case url
    case fileURL
    case color
    case unknown

    var displayName: String {
        switch self {
        case .plainText: String(localized: "Text")
        case .richText: String(localized: "Rich Text")
        case .html: String(localized: "HTML")
        case .image: String(localized: "Image")
        case .url: String(localized: "Link")
        case .fileURL: String(localized: "File")
        case .color: String(localized: "Color")
        case .unknown: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .plainText: "doc.text"
        case .richText: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .url: "link"
        case .fileURL: "doc"
        case .color: "paintpalette"
        case .unknown: "questionmark.square"
        }
    }
}
