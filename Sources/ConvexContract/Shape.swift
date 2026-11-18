/// A Convex value shape from the neutral contract.
///
/// Shapes record wire semantics only. Optionality belongs to ``Field``; nullability is a union that
/// contains ``null``.
public indirect enum Shape: Hashable, Sendable {
    /// A UTF-8 string.
    case string
    /// A boolean.
    case boolean
    /// An IEEE 754 Float64, including nonfinite values and signed zero.
    case float64
    /// A signed 64-bit integer, with an optional client-boundary meaning.
    case int64(semantic: Int64Semantic?)
    /// A Convex bytestring.
    case bytes
    /// Explicit null.
    case null
    /// An explicitly opted-in position that carries any Convex value.
    case dynamic
    /// A document identifier for the named backend table.
    case id(table: String)
    /// An ordered array of one element shape.
    case array(element: Shape)
    /// An object with known fields.
    case object(ObjectShape)
    /// An object used as a map from constrained string keys to values.
    case record(key: Shape, value: Shape)
    /// Any one of several shapes.
    case union(variants: [Shape])
    /// Exactly one value.
    case literal(LiteralValue)
    /// A fixed-length array with one shape per position.
    case tuple(elements: [Shape])
    /// A reference to an entry in the contract's named types.
    case ref(name: String)
}

/// A client-boundary meaning attached to an Int64 shape.
public enum Int64Semantic: String, Hashable, Sendable, CaseIterable {
    /// A Convex commit timestamp in nanoseconds, resolved by the backend at commit time.
    case commitTimestamp
}

/// The fields of an object shape.
public struct ObjectShape: Hashable, Sendable {
    /// The fields, sorted by wire name.
    public var fields: [Field]

    /// Creates an object shape from its fields.
    public init(fields: [Field]) {
        self.fields = fields
    }
}

/// One property of an object shape.
public struct Field: Hashable, Sendable {
    /// The exact wire key.
    public var name: String
    /// The value shape when the key is present.
    public var type: Shape
    /// Whether the key may be absent, independently of its value's nullability.
    public var optional: Bool

    /// Creates a field.
    public init(name: String, type: Shape, optional: Bool) {
        self.name = name
        self.type = type
        self.optional = optional
    }
}

/// The value of a literal shape.
public enum LiteralValue: Hashable, Sendable {
    /// A string literal.
    case string(String)
    /// A boolean literal.
    case boolean(Bool)
    /// A finite Float64 literal.
    case float64(Double)
    /// An Int64 literal, decoded from its `{"$integer": "<base64>"}` envelope.
    case int64(Int64)
}
