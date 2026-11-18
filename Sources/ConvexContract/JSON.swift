package import Foundation

/// A one-based line and column in a JSON document.
///
/// Columns count UTF-8 bytes, so they match the byte offsets that editors report for ASCII text.
public struct TextLocation: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The one-based line number.
    public var line: Int
    /// The one-based UTF-8 byte column.
    public var column: Int

    /// Creates a location from a one-based line and column.
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    /// The location formatted as `line:column`.
    public var description: String { "\(line):\(column)" }

    /// Orders locations by line, then column.
    public static func < (lhs: TextLocation, rhs: TextLocation) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// A parsed JSON value that keeps member order, duplicate members, and number lexemes.
package indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONNode])
    case object([JSONMember])

    /// A short name for diagnostics, such as `an object`.
    package var kindDescription: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }
}

/// A JSON value and the location where it starts.
package struct JSONNode: Sendable {
    package var value: JSONValue
    package var location: TextLocation
}

/// One member of a JSON object, in source order.
package struct JSONMember: Sendable {
    package var key: String
    package var keyLocation: TextLocation
    package var value: JSONNode
}

/// A JSON syntax error with its location.
package struct JSONSyntaxError: Error, Sendable {
    package var message: String
    package var location: TextLocation
}

/// A strict RFC 8259 parser.
///
/// Unlike `JSONSerialization`, it reports duplicate members to the caller, keeps number lexemes
/// exact, distinguishes booleans from numbers, and records a location for every value.
package enum JSONParser {
    private static let maximumDepth = 256

    /// Parses one complete JSON document.
    package static func parse(_ data: Data) throws(JSONSyntaxError) -> JSONNode {
        guard String(data: data, encoding: .utf8) != nil else {
            throw JSONSyntaxError(
                message: "The document is not valid UTF-8.",
                location: TextLocation(line: 1, column: 1)
            )
        }
        var scanner = Scanner(bytes: Array(data))
        scanner.skipWhitespace()
        let node = try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.isAtEnd else {
            throw scanner.error("Unexpected content after the JSON value.")
        }
        return node
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var line = 1
        var lineStart = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { index >= bytes.count }

        var location: TextLocation {
            TextLocation(line: line, column: index - lineStart + 1)
        }

        func error(_ message: String) -> JSONSyntaxError {
            JSONSyntaxError(message: message, location: location)
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0D:
                    index += 1
                case 0x0A:
                    index += 1
                    line += 1
                    lineStart = index
                default:
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws(JSONSyntaxError) -> JSONNode {
            guard depth < JSONParser.maximumDepth else {
                throw error("JSON nesting exceeds \(JSONParser.maximumDepth) levels.")
            }
            guard index < bytes.count else {
                throw error("Expected a JSON value.")
            }
            let start = location
            switch bytes[index] {
            case UInt8(ascii: "{"):
                return JSONNode(value: try parseObject(depth: depth), location: start)
            case UInt8(ascii: "["):
                return JSONNode(value: try parseArray(depth: depth), location: start)
            case UInt8(ascii: "\""):
                return JSONNode(value: .string(try parseString()), location: start)
            case UInt8(ascii: "t"):
                try expectWord("true")
                return JSONNode(value: .bool(true), location: start)
            case UInt8(ascii: "f"):
                try expectWord("false")
                return JSONNode(value: .bool(false), location: start)
            case UInt8(ascii: "n"):
                try expectWord("null")
                return JSONNode(value: .null, location: start)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return JSONNode(value: .number(try parseNumber()), location: start)
            default:
                throw error("Expected a JSON value.")
            }
        }

        mutating func expectWord(_ word: StaticString) throws(JSONSyntaxError) {
            let count = word.utf8CodeUnitCount
            let matches = word.withUTF8Buffer { expected in
                index + count <= bytes.count
                    && bytes[index..<(index + count)].elementsEqual(expected)
            }
            guard matches else {
                throw error("Expected `\(word)`.")
            }
            index += count
        }

        mutating func parseObject(depth: Int) throws(JSONSyntaxError) -> JSONValue {
            index += 1
            var members: [JSONMember] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw error("Expected a string object key.")
                }
                let keyLocation = location
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw error("Expected `:` after an object key.")
                }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(JSONMember(key: key, keyLocation: keyLocation, value: value))
                skipWhitespace()
                guard index < bytes.count else {
                    throw error("Unterminated object.")
                }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else {
                    throw error("Expected `,` or `}` in an object.")
                }
                index += 1
                return .object(members)
            }
        }

        mutating func parseArray(depth: Int) throws(JSONSyntaxError) -> JSONValue {
            index += 1
            var elements: [JSONNode] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else {
                    throw error("Unterminated array.")
                }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else {
                    throw error("Expected `,` or `]` in an array.")
                }
                index += 1
                return .array(elements)
            }
        }

        mutating func parseString() throws(JSONSyntaxError) -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flushRun(upTo end: Int, into scalars: inout String.UnicodeScalarView) {
                if runStart < end {
                    scalars.append(
                        contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self)
                            .unicodeScalars
                    )
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    flushRun(upTo: index, into: &scalars)
                    index += 1
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    flushRun(upTo: index, into: &scalars)
                    index += 1
                    scalars.append(try parseEscape())
                    runStart = index
                case 0x00..<0x20:
                    throw error("Unescaped control character in a string.")
                default:
                    index += 1
                }
            }
            throw error("Unterminated string.")
        }

        mutating func parseEscape() throws(JSONSyntaxError) -> Unicode.Scalar {
            guard index < bytes.count else {
                throw error("Unterminated escape sequence.")
            }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return "\""
            case UInt8(ascii: "\\"): return "\\"
            case UInt8(ascii: "/"): return "/"
            case UInt8(ascii: "b"): return "\u{08}"
            case UInt8(ascii: "f"): return "\u{0C}"
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "u"):
                let first = try parseHexQuad()
                if (0xD800...0xDBFF).contains(first) {
                    guard
                        index + 1 < bytes.count,
                        bytes[index] == UInt8(ascii: "\\"),
                        bytes[index + 1] == UInt8(ascii: "u")
                    else {
                        throw error("Unpaired UTF-16 surrogate in a string escape.")
                    }
                    index += 2
                    let second = try parseHexQuad()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw error("Unpaired UTF-16 surrogate in a string escape.")
                    }
                    let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    guard let scalar = Unicode.Scalar(value) else {
                        throw error("Invalid Unicode escape.")
                    }
                    return scalar
                }
                guard let scalar = Unicode.Scalar(first) else {
                    throw error("Unpaired UTF-16 surrogate in a string escape.")
                }
                return scalar
            default:
                throw error("Invalid escape sequence.")
            }
        }

        mutating func parseHexQuad() throws(JSONSyntaxError) -> UInt32 {
            guard index + 4 <= bytes.count else {
                throw error("Incomplete Unicode escape.")
            }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"):
                    digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"):
                    digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw error("Invalid hexadecimal digit in a Unicode escape.")
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws(JSONSyntaxError) -> String {
            let start = index
            if bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count else {
                throw error("Incomplete number.")
            }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if isDigit(bytes[index]) {
                skipDigits()
            } else {
                throw error("Expected a digit.")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else {
                    throw error("Expected a digit after the decimal point.")
                }
                skipDigits()
            }
            if index < bytes.count,
                bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E")
            {
                index += 1
                if index < bytes.count,
                    bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
                {
                    index += 1
                }
                guard index < bytes.count, isDigit(bytes[index]) else {
                    throw error("Expected a digit in the exponent.")
                }
                skipDigits()
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        mutating func skipDigits() {
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
            }
        }
    }
}
