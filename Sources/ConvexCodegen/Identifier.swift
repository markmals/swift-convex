/// Converts backend names into Swift identifiers deterministically.
///
/// Names split into words at separators, lower-to-upper transitions, and the end of an uppercase
/// run (`HTTPServer` is `HTTP` and `Server`). Known acronyms keep one spelling (`channelId` becomes
/// `channelID`), an author's uppercase acronym is kept, and an all-uppercase name is treated as
/// ordinary words (`MAX_SIZE` becomes `maxSize`). Only ASCII letters and digits survive.
enum Identifier {
    /// Acronyms normalized to one spelling, keyed by their lowercase form.
    static let acronyms: [String: String] = [
        "api": "API", "apis": "APIs",
        "html": "HTML",
        "http": "HTTP", "https": "HTTPS",
        "id": "ID", "ids": "IDs",
        "ip": "IP",
        "json": "JSON",
        "jwt": "JWT",
        "sql": "SQL",
        "uri": "URI", "uris": "URIs",
        "url": "URL", "urls": "URLs",
        "uuid": "UUID", "uuids": "UUIDs",
        "xml": "XML",
    ]

    /// Swift keywords that a member name may use only with backticks.
    static let keywords: Set<String> = [
        "Any", "Protocol", "Self", "Type", "as", "associatedtype", "await", "break", "case",
        "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
        "inout", "internal", "is", "let", "nil", "open", "operator", "precedencegroup", "private",
        "protocol", "public", "repeat", "rethrows", "return", "self", "static", "struct",
        "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while",
    ]

    /// Names that cannot be a generated member even with backticks.
    static let reservedMemberNames: Set<String> = [
        "Protocol", "Self", "Type", "_", "deinit", "init", "self", "subscript", "super",
    ]

    /// Splits a backend name into ASCII words.
    static func words(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let hasLowercase = scalars.contains { $0.isASCIILowercase }
        var words: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                let word = String(current)
                words.append(hasLowercase ? word : word.lowercased())
                current.removeAll()
            }
        }
        for (index, scalar) in scalars.enumerated() {
            guard scalar.isASCIIAlphanumeric else {
                flush()
                continue
            }
            if !current.isEmpty, scalar.isASCIIUppercase {
                let previous = scalars[index - 1]
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                if previous.isASCIILowercase || previous.isASCIIDigit {
                    flush()
                } else if previous.isASCIIUppercase, next?.isASCIILowercase == true {
                    flush()
                }
            }
            current.append(scalar)
        }
        flush()
        return words
    }

    /// The UpperCamelCase spelling of a backend name, or `nil` when it has no ASCII letters or digits.
    static func upperCamel(_ text: String) -> String? {
        let parts = words(text)
        guard !parts.isEmpty else {
            return nil
        }
        return prefixedIfNeeded(parts.map(capitalized).joined())
    }

    /// The lowerCamelCase spelling of a backend name, or `nil` when it has no ASCII letters or digits.
    static func lowerCamel(_ text: String) -> String? {
        let parts = words(text)
        guard let first = parts.first else {
            return nil
        }
        return prefixedIfNeeded(first.lowercased() + parts.dropFirst().map(capitalized).joined())
    }

    /// Uppercases the first character of an existing identifier.
    static func upperFirst(_ identifier: String) -> String {
        guard let first = identifier.first else {
            return identifier
        }
        return first.uppercased() + identifier.dropFirst()
    }

    /// Lowercases the leading uppercase run of an existing identifier (`URLRequest` is `urlRequest`).
    static func lowerFirst(_ identifier: String) -> String {
        guard let first = words(identifier).first, identifier.hasPrefix(first) else {
            return identifier
        }
        return first.lowercased() + identifier.dropFirst(first.count)
    }

    /// Whether the text is an ASCII Swift identifier.
    static func isValid(_ text: String) -> Bool {
        guard text != "_", let first = text.unicodeScalars.first,
            first.isASCIILetter || first == "_"
        else {
            return false
        }
        return text.unicodeScalars.allSatisfy { $0.isASCIIAlphanumeric || $0 == "_" }
    }

    /// The identifier as written in source, with backticks around keywords.
    static func escaped(_ identifier: String) -> String {
        keywords.contains(identifier) ? "`\(identifier)`" : identifier
    }

    private static func capitalized(_ word: String) -> String {
        if let acronym = acronyms[word.lowercased()] {
            return acronym
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private static func prefixedIfNeeded(_ identifier: String) -> String {
        guard let first = identifier.unicodeScalars.first, first.isASCIIDigit else {
            return identifier
        }
        return "_" + identifier
    }
}

extension Unicode.Scalar {
    fileprivate var isASCIILowercase: Bool { ("a"..."z").contains(self) }
    fileprivate var isASCIIUppercase: Bool { ("A"..."Z").contains(self) }
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    fileprivate var isASCIILetter: Bool { isASCIILowercase || isASCIIUppercase }
    fileprivate var isASCIIAlphanumeric: Bool { isASCIILetter || isASCIIDigit }
}
