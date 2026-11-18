public import Foundation

/// A validated neutral Convex contract, format version 1.
///
/// Creating a document parses the JSON strictly and validates every reference before returning, so
/// a value of this type is always complete: references resolve, tables exist, and no named type is
/// recursive. Functions and tables are sorted by their backend names.
public struct ContractDocument: Sendable {
    /// The only format version this module reads.
    public static let supportedFormatVersion = 1

    /// The tool versions and source fingerprint that produced the contract.
    public var provenance: Provenance
    /// Public client-callable functions, sorted by Convex address.
    public var functions: [ContractFunction]
    /// Tables, sorted by name.
    public var tables: [ContractTable]
    /// Named shapes keyed by their stable backend-derived names.
    public var types: [String: Shape]

    package var locations: [ContractPath: TextLocation]

    /// Parses and validates a contract document.
    ///
    /// - Throws: ``ContractError`` with every structural and semantic problem found. An unsupported
    ///   format version is reported alone, before any other validation.
    public init(data: Data) throws(ContractError) {
        let root: JSONNode
        do throws(JSONSyntaxError) {
            root = try JSONParser.parse(data)
        } catch {
            throw ContractError(diagnostics: [
                ContractDiagnostic(code: .syntax, message: error.message, location: error.location)
            ])
        }
        var reader = ContractReader()
        let document = try reader.read(root)
        self = document
    }

    package init(
        provenance: Provenance,
        functions: [ContractFunction],
        tables: [ContractTable],
        types: [String: Shape],
        locations: [ContractPath: TextLocation]
    ) {
        self.provenance = provenance
        self.functions = functions
        self.tables = tables
        self.types = types
        self.locations = locations
    }

    /// The JSON location of the value at a contract path, when that path names a value in the file.
    public func location(of path: ContractPath) -> TextLocation? {
        locations[path]
    }

    /// Follows references until reaching a shape that is not a reference.
    ///
    /// Validation guarantees that references resolve and are acyclic.
    public func resolved(_ shape: Shape) -> Shape {
        var current = shape
        while case .ref(let name) = current, let target = types[name] {
            current = target
        }
        return current
    }
}

/// The tools and inputs that produced a contract.
public struct Provenance: Hashable, Sendable {
    /// The exporter's version.
    public var exporterVersion: String
    /// The Convex package version the backend used.
    public var convexVersion: String
    /// The TypeScript compiler version the exporter used.
    public var typescriptVersion: String
    /// A SHA-256 hexadecimal digest of the exported inputs.
    public var sourceHash: String

    /// Creates provenance.
    public init(
        exporterVersion: String,
        convexVersion: String,
        typescriptVersion: String,
        sourceHash: String
    ) {
        self.exporterVersion = exporterVersion
        self.convexVersion = convexVersion
        self.typescriptVersion = typescriptVersion
        self.sourceHash = sourceHash
    }
}

/// A public client-callable Convex function.
public struct ContractFunction: Hashable, Sendable {
    /// The exact Convex address, such as `messages:list`.
    public var path: String
    /// The module path segments, such as `["admin", "users"]`.
    public var module: [String]
    /// The backend export name.
    public var name: String
    /// The operation kind, which decides how clients may call the function.
    public var kind: FunctionKind
    /// The argument object.
    public var arguments: ObjectShape
    /// The client-visible result, after Convex's return normalization.
    public var result: Shape
    /// How the exporter determined the types.
    public var typeSource: TypeSource
    /// The function's backend source location, when the exporter recorded one.
    public var source: SourceLocation?

    /// Creates a function descriptor.
    public init(
        path: String,
        module: [String],
        name: String,
        kind: FunctionKind,
        arguments: ObjectShape,
        result: Shape,
        typeSource: TypeSource,
        source: SourceLocation?
    ) {
        self.path = path
        self.module = module
        self.name = name
        self.kind = kind
        self.arguments = arguments
        self.result = result
        self.typeSource = typeSource
        self.source = source
    }
}

/// The kind of a Convex function.
public enum FunctionKind: String, Hashable, Sendable, CaseIterable {
    /// A read-only, reactive function.
    case query
    /// A transactional write.
    case mutation
    /// A function that may have side effects outside the database.
    case action
}

/// How the exporter determined a function's types.
public enum TypeSource: String, Hashable, Sendable, CaseIterable {
    /// Inferred from TypeScript source by the compiler.
    case inferred
    /// Derived from Convex validators.
    case validator
    /// Contains explicitly opted-in dynamic positions.
    case dynamic
}

/// A repository-relative backend source location.
public struct SourceLocation: Hashable, Sendable, CustomStringConvertible {
    /// The repository-relative file path.
    public var file: String
    /// The one-based line number.
    public var line: Int

    /// Creates a source location.
    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }

    /// The location formatted as `file:line`.
    public var description: String { "\(file):\(line)" }
}

/// A backend table.
public struct ContractTable: Hashable, Sendable {
    /// The backend table name.
    public var name: String
    /// The document shape, including the `_id` and `_creationTime` system fields.
    public var document: Shape

    /// Creates a table.
    public init(name: String, document: Shape) {
        self.name = name
        self.document = document
    }
}
