import Foundation

/// Distinguishes an omitted field from a present value, including a present nil.
public enum ConvexField<Value: Sendable>: Sendable {
    /// Leaves the wire key absent.
    case omitted
    /// Includes the wire key; a nullable nil encodes as explicit null.
    case value(Value)
}

extension ConvexField: Equatable where Value: Equatable {}
extension ConvexField: Hashable where Value: Hashable {}

extension KeyedEncodingContainer {
    /// Includes this key even when a nullable value is nil.
    public mutating func encodeConvex<Value: ConvexValueCodable>(_ value: Value, forKey key: Key)
        throws
    {
        try value.encodeConvex(to: superEncoder(forKey: key))
    }

    /// Omits nil rather than sending null for an optional nonnullable field.
    public mutating func encodeConvexIfPresent<Value: ConvexValueCodable>(
        _ value: Value?,
        forKey key: Key
    ) throws {
        if let value { try encodeConvex(value, forKey: key) }
    }

    /// Preserves the distinction between omission and a present nullable value.
    public mutating func encodeConvexField<Value: ConvexValueCodable>(
        _ field: ConvexField<Value>,
        forKey key: Key
    ) throws {
        if case .value(let value) = field { try encodeConvex(value, forKey: key) }
    }
}

extension KeyedDecodingContainer {
    /// Requires the key; only an explicitly nullable type accepts null.
    public func decodeConvex<Value: ConvexValueCodable>(_ type: Value.Type, forKey key: Key) throws
        -> Value
    {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Missing required Convex field")
            )
        }
        return try Value.decodeConvex(from: superDecoder(forKey: key))
    }

    /// Accepts absence, but delegates a present null to the declared value type.
    public func decodeConvexIfPresent<Value: ConvexValueCodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Value? {
        guard contains(key) else { return nil }
        return try decodeConvex(type, forKey: key)
    }

    /// Reports key presence independently of value nullability.
    public func decodeConvexField<Value: ConvexValueCodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> ConvexField<Value> {
        guard contains(key) else { return .omitted }
        return try .value(decodeConvex(type, forKey: key))
    }
}

extension UnkeyedEncodingContainer {
    /// Preserves the element's Convex wire kind.
    public mutating func encodeConvex<Value: ConvexValueCodable>(_ value: Value) throws {
        try value.encodeConvex(to: superEncoder())
    }
}

extension UnkeyedDecodingContainer {
    /// Decodes exactly one element with its declared Convex wire kind.
    public mutating func decodeConvex<Value: ConvexValueCodable>(_ type: Value.Type) throws -> Value
    {
        try Value.decodeConvex(from: superDecoder())
    }
}
