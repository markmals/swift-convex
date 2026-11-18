/// A problem found while reading a contract or generating code from it.
public struct ContractDiagnostic: Hashable, Sendable, CustomStringConvertible {
    /// A stable identifier for the kind of problem, independent of message wording.
    ///
    /// Modules that report their own problems add codes in extensions.
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        /// The code's stable spelling.
        public let rawValue: String

        /// Creates a code from its stable spelling.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The code's stable spelling.
        public var description: String { rawValue }
    }

    /// The input file a diagnostic refers to.
    public enum File: Hashable, Sendable {
        /// The neutral contract document.
        case contract
        /// The Swift generation configuration.
        case configuration
    }

    /// The kind of problem.
    public var code: Code
    /// A human-readable explanation, including the fix when one is known.
    public var message: String
    /// The contract path of the affected declaration or shape, when there is one.
    public var path: ContractPath?
    /// The input file that contains the problem.
    public var file: File
    /// The JSON location of the problem, when it is known.
    public var location: TextLocation?
    /// The backend source location of the affected function, when the contract records one.
    public var source: SourceLocation?

    /// Creates a diagnostic.
    public init(
        code: Code,
        message: String,
        path: ContractPath? = nil,
        file: File = .contract,
        location: TextLocation? = nil,
        source: SourceLocation? = nil
    ) {
        self.code = code
        self.message = message
        self.path = path
        self.file = file
        self.location = location
        self.source = source
    }

    /// The path, message, and backend source location, without the input file location.
    public var description: String {
        var text = ""
        if let path {
            text += "\(path): "
        }
        text += message
        if let source {
            text += " (defined at \(source))"
        }
        return text
    }
}

extension ContractDiagnostic.Code {
    /// The document is not well-formed JSON.
    public static let syntax = Self(rawValue: "syntax")
    /// The document declares a format version this generator does not support.
    public static let unsupportedFormatVersion = Self(rawValue: "unsupportedFormatVersion")
    /// An object contains a member that the format does not define.
    public static let unexpectedKey = Self(rawValue: "unexpectedKey")
    /// An object lacks a required member.
    public static let missingKey = Self(rawValue: "missingKey")
    /// A JSON object repeats a member name.
    public static let duplicateKey = Self(rawValue: "duplicateKey")
    /// A member has the wrong JSON type or an invalid value.
    public static let invalidValue = Self(rawValue: "invalidValue")
    /// A shape uses a `kind` that the format does not define.
    public static let unknownShapeKind = Self(rawValue: "unknownShapeKind")
    /// A `ref` shape names a type that `types` does not define.
    public static let danglingReference = Self(rawValue: "danglingReference")
    /// An `id` shape names a table that `tables` does not define.
    public static let unknownTable = Self(rawValue: "unknownTable")
    /// Two functions share a Convex address.
    public static let duplicateFunction = Self(rawValue: "duplicateFunction")
    /// Two tables share a name.
    public static let duplicateTable = Self(rawValue: "duplicateTable")
    /// Two named types share a name.
    public static let duplicateType = Self(rawValue: "duplicateType")
    /// An object shape repeats a field name.
    public static let duplicateField = Self(rawValue: "duplicateField")
    /// Named types refer to each other in a cycle.
    public static let recursiveReference = Self(rawValue: "recursiveReference")
    /// A literal is not a string, boolean, finite number, or canonical Int64 envelope.
    public static let invalidLiteral = Self(rawValue: "invalidLiteral")
    /// A record key is not a string, ID, string literal, or union of those.
    public static let invalidRecordKey = Self(rawValue: "invalidRecordKey")
    /// A union has no variants.
    public static let emptyUnion = Self(rawValue: "emptyUnion")
}

/// The diagnostics that prevented reading a contract or generating code from it.
public struct ContractError: Error, Sendable, CustomStringConvertible {
    /// The problems, in a deterministic order.
    public var diagnostics: [ContractDiagnostic]

    /// Creates an error from one or more diagnostics.
    public init(diagnostics: [ContractDiagnostic]) {
        self.diagnostics = diagnostics
    }

    /// Every diagnostic on its own line.
    public var description: String {
        diagnostics.map(\.description).joined(separator: "\n")
    }
}

extension [ContractDiagnostic] {
    /// Orders diagnostics by file, location, path, and code so reports are reproducible.
    package func sortedForReport() -> [ContractDiagnostic] {
        sorted { lhs, rhs in
            if lhs.file != rhs.file {
                return lhs.file == .configuration
            }
            switch (lhs.location, rhs.location) {
            case (let left?, let right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                break
            }
            let leftPath = lhs.path?.description ?? ""
            let rightPath = rhs.path?.description ?? ""
            if leftPath != rightPath {
                return leftPath < rightPath
            }
            if lhs.code != rhs.code {
                return lhs.code.rawValue < rhs.code.rawValue
            }
            return lhs.message < rhs.message
        }
    }
}
