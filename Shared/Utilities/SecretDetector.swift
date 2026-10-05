import Foundation

/// What a detected secret is. Its label leads the masked preview.
enum SecretKind: Equatable, Sendable {
    case apiKey, token, privateKey, card

    /// `bundle` holds the catalog; tests pass one language's `.lproj`.
    func label(bundle: Bundle = .main) -> String {
        switch self {
        case .apiKey: String(localized: "API key", bundle: bundle, comment: "Label of a masked secret clip")
        case .token: String(localized: "Token", bundle: bundle, comment: "Label of a masked secret clip")
        case .privateKey: String(localized: "Private key", bundle: bundle, comment: "Label of a masked secret clip")
        case .card: String(localized: "Card", bundle: bundle, comment: "Label of a masked secret clip: a card number")
        }
    }
}

/// Recognizes well-known secret formats in a copy. Pure. No entropy guessing: it would match too much everyday text.
/// A key must be the whole copy: alone, quoted, as an assignment (`NAME=key`, `const K = "key";`, `"k": "key",`), as a
/// header value (`Bearer key`, `curl -H "…"`), or one line of a copied `.env` file. A private key may follow a label.
enum SecretDetector {
    /// "Protect secrets" in Settings, on by default.
    static let protectDefaultsKey = "protectSecrets"
    /// ponytail: longer copies are never checked; a private key is a few KB, a key or a card far less.
    private static let maxLength = 100_000

    /// Before a key, the optional `export`, `const`, `let`, `var` or `curl -H`, a name, quoted or not, then `=` or
    /// `:`, a quote and `Bearer `. After it, a quote and a `,` or `;`.
    private static let lead =
        #"^(?:(?:export|const|let|var)\s+|curl\s+(?:-H|--header)\s+)?(?:["']?[A-Za-z_][A-Za-z0-9_.-]*["']?\s*[=:]\s*)?["']?(?:Bearer\s+)?"#
    private static let tail = #"["']?[,;]?$"#

    /// Anthropic before OpenAI: both start with `sk-`. Google keys are 39 characters, OpenAI's at least 32, with a
    /// digit and an uppercase letter, so a hyphenated name like `sk-learn-…` is not one.
    private static let keys: [(SecretKind, NSRegularExpression)] = ([
        (.apiKey, #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
        (.token, #"gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}"#),
        (.apiKey, #"(?:sk|rk)_live_[A-Za-z0-9]{16,}"#),
        (.token, #"xox[abprs]-[A-Za-z0-9-]{10,}"#),
        (.apiKey, #"sk-ant-[A-Za-z0-9_-]{20,}"#),
        (.apiKey, #"sk-(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Z])[A-Za-z0-9_-]{29,}"#),
        (.apiKey, #"AIza[0-9A-Za-z_-]{35}"#),
        (.token, #"eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#),
    ] as [(SecretKind, String)]).map { ($0.0, regex(lead + "(?:" + $0.1 + ")" + tail)) }

    /// Anywhere in the copy: the header alone is unambiguous, and a label line often comes before it.
    private static let privateKey = regex(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#)

    /// One line of a `.env` file.
    private static let envLine = regex(#"^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=.*$"#)

    /// 13–19 digits starting 2–6 (every card network; no card starts with 1, which keeps millisecond timestamps
    /// out). Separators follow a card's own grouping, 4-4-4-… or Amex's 4-6-5, never an order number's 3-7-7.
    private static let card = regex(
        #"^[2-6][0-9]{12,18}$|^[2-6][0-9]{3}([ -])[0-9]{4}\1[0-9]{4}(?:\1[0-9]{1,4}){1,2}$|^3[0-9]{3}([ -])[0-9]{6}\2[0-9]{4,5}$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Fixed patterns, checked by the tests: a typo fails every run, never a user's.
        try! NSRegularExpression(pattern: pattern)
    }

    static func kind(of text: String) -> SecretKind? { match(of: text)?.kind }

    /// The secret in a copy, and the text its mask shows the end of: the copy itself, or in a `.env` copy, the key's line.
    static func match(of text: String) -> (kind: SecretKind, value: String)? {
        guard text.utf8.count <= maxLength else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(privateKey, text) { return (.privateKey, text) }
        if matches(card, text) {
            let digits = text.filter { $0 != " " && $0 != "-" }
            if passesLuhn(digits), hasCardLength(digits) { return (.card, text) }
        }
        if let kind = keyKind(text) { return (kind, text) }
        return envMatch(text)
    }

    private static func keyKind(_ text: String) -> SecretKind? {
        keys.first { matches($0.1, text) }?.0
    }

    /// A `.env` file copied whole: every line that is not blank or a `#` comment is `NAME=value`. The first key decides.
    private static func envMatch(_ text: String) -> (kind: SecretKind, value: String)? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count > 1, lines.allSatisfy({ matches(envLine, $0) }) else { return nil }
        return lines.lazy.compactMap { line in keyKind(line).map { ($0, line) } }.first
    }

    /// The lengths each network issues, by prefix. An IMEI (15 digits from 35) or an EAN-13 barcode passes Luhn too.
    private static func hasCardLength(_ digits: String) -> Bool {
        guard let first4 = Int(digits.prefix(4)) else { return false }
        let count = digits.count
        switch first4 {
        case 3400...3499, 3700...3799: return count == 15  // American Express
        case 3000...3059, 3600...3699, 3800...3999: return (14...19).contains(count)  // Diners Club
        case 4000...4999: return count == 16 || count == 19  // Visa
        case 5100...5599, 2221...2720: return count == 16  // Mastercard
        case 3500...3599, 6000...6999: return (16...19).contains(count)  // JCB, Discover, UnionPay
        default: return false
        }
    }

    /// A flagged copy's masked preview, from its match. One that no longer matches (detection changed since it was
    /// flagged) shows as a token.
    static func mask(_ text: String) -> String {
        let match = match(of: text)
        return mask(match?.value ?? text, kind: match?.kind ?? .token)
    }

    /// The masked preview: the label and the last 4 letters or digits, "API key •••• 3f9a". A private key's come from
    /// its body, before the `-----END` line.
    static func mask(_ text: String, kind: SecretKind, bundle: Bundle = .main) -> String {
        let body = kind == .privateKey ? text.components(separatedBy: "-----END").first ?? text : text
        let last = String(body.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.suffix(4))
        return "\(kind.label(bundle: bundle)) •••• \(last)"
    }

    /// `digits` holds ASCII digits only.
    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, char) in digits.reversed().enumerated() {
            guard let d = char.wholeNumberValue else { return false }
            sum += i % 2 == 0 ? d : (d * 2 > 9 ? d * 2 - 9 : d * 2)
        }
        return sum % 10 == 0
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension SecretDetector {
    /// iOS keeps the secret settings in the App Group, so the keyboard reads them too.
    static var settings: UserDefaults {
        #if os(iOS)
        SharedDefaults.store ?? .standard
        #else
        .standard
        #endif
    }

    static var isProtecting: Bool { settings.object(forKey: protectDefaultsKey) as? Bool ?? true }

    /// What a capture stores in `isSensitive`: a copy whose text is a secret, while "Protect secrets" is on.
    /// A files clip's text is its file names, never the copy.
    static func flags(_ text: String?, type: ContentType, protects: Bool = isProtecting) -> Bool {
        guard protects, let text, ![.image, .files, .fileURL].contains(type) else { return false }
        return kind(of: text) != nil
    }
}

extension ClipboardItem {
    /// What cards, rows and search show for a secret: "API key •••• 3f9a". Nil for any other clip.
    var secretMask: String? {
        guard isSensitive else { return nil }
        return SecretDetector.mask(textContent ?? "")
    }
}
