import ConvexContract

/// A dotted Swift type name, starting at the generated root namespace.
struct QualifiedName: Hashable, Comparable, CustomStringConvertible {
    var components: [String]

    init(_ components: [String]) {
        self.components = components
    }

    var name: String { components.last ?? "" }

    var parent: QualifiedName { QualifiedName(Array(components.dropLast())) }

    func child(_ name: String) -> QualifiedName {
        QualifiedName(components + [name])
    }

    var description: String { components.joined(separator: ".") }

    static func < (lhs: QualifiedName, rhs: QualifiedName) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// A Swift type expression in generated code.
indirect enum SwiftType: Hashable {
    case string
    case bool
    case double
    case int64
    case data
    case convexNull
    case convexValue
    case documentID(table: QualifiedName)
    case array(SwiftType)
    case dictionary(key: SwiftType, value: SwiftType)
    case optional(SwiftType)
    case field(SwiftType)
    case named(QualifiedName)

    /// The fully qualified spelling, immune to shadowing by generated names.
    var source: String {
        switch self {
        case .string: "Swift.String"
        case .bool: "Swift.Bool"
        case .double: "Swift.Double"
        case .int64: "Swift.Int64"
        case .data: "Foundation.Data"
        case .convexNull: "Convex.ConvexNull"
        case .convexValue: "Convex.ConvexValue"
        case .documentID(let table): "Convex.DocumentID<\(table)>"
        case .array(let element): "[\(element.source)]"
        case .dictionary(let key, let value): "[\(key.source): \(value.source)]"
        case .optional(let wrapped): "\(wrapped.source)?"
        case .field(let value): "Convex.ConvexField<\(value.source)>"
        case .named(let name): name.description
        }
    }

    /// Whether the spelling mentions `Foundation.Data`.
    var usesData: Bool {
        switch self {
        case .data: true
        case .string, .bool, .double, .int64, .convexNull, .convexValue, .documentID, .named: false
        case .array(let element): element.usesData
        case .dictionary(let key, let value): key.usesData || value.usesData
        case .optional(let wrapped): wrapped.usesData
        case .field(let value): value.usesData
        }
    }
}

/// How a generated property encodes absence and null.
enum Presence: Hashable {
    /// The key is always present; a nullable type encodes `nil` as null.
    case required
    /// The key is omitted for `nil`; a present null is rejected when decoding.
    case optional
    /// A `ConvexField` keeps omission, null, and a value distinct.
    case optionalNullable
}

/// A stored property of a generated model or request.
struct Property: Hashable {
    /// The Swift identifier, without backticks.
    var name: String
    /// The exact wire key.
    var wireName: String
    /// The declared Swift type, including `?` or `ConvexField` for optional fields.
    var type: SwiftType
    /// The type passed to the keyed coding helpers.
    var valueType: SwiftType
    var presence: Presence
    var documentation: [String]
}

/// A non-null wire category used to dispatch a union; `Optional` handles null.
enum WireKind: Int, Hashable, Comparable, CaseIterable {
    case boolean
    case string
    case float64
    case int64
    case bytes
    case array
    case object

    /// The matching `ConvexWireKind` case name.
    var caseName: String {
        switch self {
        case .boolean: "boolean"
        case .string: "string"
        case .float64: "float64"
        case .int64: "int64"
        case .bytes: "bytes"
        case .array: "array"
        case .object: "object"
        }
    }

    /// The scalar Swift type that decodes literal values of this kind.
    var scalarType: SwiftType? {
        switch self {
        case .boolean: .bool
        case .string: .string
        case .float64: .double
        case .int64: .int64
        case .bytes, .array, .object: nil
        }
    }

    static func < (lhs: WireKind, rhs: WireKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension LiteralValue {
    var wireKind: WireKind {
        switch self {
        case .string: .string
        case .boolean: .boolean
        case .float64: .float64
        case .int64: .int64
        }
    }

    /// A total order used to keep generated cases and branches stable.
    static func precedes(_ lhs: LiteralValue, _ rhs: LiteralValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let left), .string(let right)): left < right
        case (.boolean(let left), .boolean(let right)): !left && right
        case (.float64(let left), .float64(let right)): left < right
        case (.int64(let left), .int64(let right)): left < right
        default: lhs.wireKind < rhs.wireKind
        }
    }
}

/// One case of a generated union or literal enum.
struct UnionCase: Hashable {
    var name: String
    /// The associated value type; `nil` for a literal case.
    var payload: SwiftType?
    /// The literal this case encodes; `nil` for a payload case.
    var literal: LiteralValue?
    var documentation: [String]
}

/// Literal values that select one case.
struct Branch: Hashable {
    var values: [LiteralValue]
    var caseName: String
    /// Whether the case decodes its payload from the same decoder after matching.
    var decodesPayload: Bool
}

/// How one wire kind selects a case.
enum Match: Hashable {
    /// Exactly one case accepts this wire kind; its payload validates the value.
    case single(caseName: String)
    /// Cases are selected by the scalar value of this wire kind.
    case values([Branch])
    /// Object cases are selected by a required literal field.
    case discriminant(field: String, branches: [Branch])
}

/// The cases accepted for one wire kind.
struct KindBranch: Hashable {
    var kind: WireKind
    var match: Match
}

/// A generated enum for a disjoint union or a set of literals.
struct Union: Hashable {
    var cases: [UnionCase]
    /// Sorted by wire kind, with a single branch decoded without inspecting the kind.
    var branches: [KindBranch]

    /// Whether every case is a literal without a payload.
    var isLiteralOnly: Bool { cases.allSatisfy { $0.payload == nil } }

    /// Whether every case is a string literal, which allows a `String` raw value and object-key use.
    var isStringLiteralOnly: Bool {
        cases.allSatisfy { unionCase in
            guard case .string = unionCase.literal else { return false }
            return true
        }
    }
}

/// A fixed-length tuple element.
struct TupleElement: Hashable {
    var name: String
    var type: SwiftType
    var documentation: [String]
}

/// A generated request for one backend function.
struct Request: Hashable {
    var kind: FunctionKind
    var functionPath: String
    var properties: [Property]
}

/// A generated declaration and its place in the namespace tree.
struct Declaration: Hashable {
    enum Kind: Hashable {
        /// A caseless enum that only scopes other declarations.
        case namespace
        /// A `ConvexTable` marker for the named backend table.
        case table(wireName: String)
        /// A struct for an object shape.
        case model([Property])
        /// A struct for a fixed-length tuple.
        case tuple([TupleElement])
        /// An enum for a union or literals.
        case union(Union)
        /// A type alias.
        case alias(SwiftType)
        /// A request struct.
        case request(Request)
    }

    var name: QualifiedName
    var documentation: [String]
    var kind: Kind
}

/// The complete Swift translation of a contract.
struct GeneratedModule {
    var provenance: Provenance
    var declarations: [Declaration]

    /// Looks up a declaration by its dotted name, for example `API.Messages.List`.
    func declaration(named name: String) -> Declaration? {
        declarations.first { $0.name.description == name }
    }
}
