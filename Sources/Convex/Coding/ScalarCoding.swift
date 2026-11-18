import Foundation

extension String: ConvexValueCodable {
    /// Encodes a UTF-8 JSON string without interpreting it as an identifier.
    public func encodeConvex(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self)
    }

    /// Rejects non-string wire values without coercion.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        try decoder.singleValueContainer().decode(Self.self)
    }
}

extension Bool: ConvexValueCodable {
    /// Encodes a boolean rather than a numeric surrogate.
    public func encodeConvex(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self)
    }

    /// Rejects numeric and string representations of booleans.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        try decoder.singleValueContainer().decode(Self.self)
    }
}

/// Represents a successful null-only result, including normalized backend void returns.
public struct ConvexNull: ConvexValueCodable, Hashable {
    /// Creates the sole null value.
    public init() {}

    /// Encodes an explicit JSON null.
    public func encodeConvex(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }

    /// Rejects every value other than explicit null.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        let container = try decoder.singleValueContainer()
        guard container.decodeNil() else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected Convex null"
            )
        }
        return Self()
    }
}

extension Optional: ConvexValueCodable where Wrapped: ConvexValueCodable {
    /// Encodes nil as null; object-key omission is controlled by the keyed helper.
    public func encodeConvex(to encoder: any Encoder) throws {
        switch self {
        case .some(let value): try value.encodeConvex(to: encoder)
        case .none: try ConvexNull().encodeConvex(to: encoder)
        }
    }

    /// Decodes null as nil without treating a missing object key as present.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        if try decoder.singleValueContainer().decodeNil() { return nil }
        return try Wrapped.decodeConvex(from: decoder)
    }
}
