import SwiftUI

enum TextHighlighter {
    /// `base`, when given, is `text` already styled (code colors); the matches are marked on top of it.
    static func highlight(
        _ text: String,
        query: String,
        over base: AttributedString? = nil,
        backgroundColor: Color = .accentColor.opacity(0.3)
    ) -> AttributedString {
        var attributed = base ?? AttributedString(text)
        guard !query.isEmpty else { return attributed }

        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()
        var searchStart = lowercasedText.startIndex

        while let range = lowercasedText.range(of: lowercasedQuery, range: searchStart..<lowercasedText.endIndex) {
            if let attrStart = AttributedString.Index(range.lowerBound, within: attributed),
               let attrEnd = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[attrStart..<attrEnd].backgroundColor = backgroundColor
            }
            searchStart = range.upperBound
        }

        return attributed
    }
}
