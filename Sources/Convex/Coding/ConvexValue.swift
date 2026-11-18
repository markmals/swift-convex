public import Foundation

/// Represents explicitly dynamic contract positions without erasing Convex wire kinds.
public enum ConvexValue: Sendable, Equatable, ConvexValueCodable {
    /// Explicit null, never a missing field.
    case null
    /// A boolean wire value.
    case boolean(Bool)
    /// A UTF-8 string wire value.
    case string(String)
    /// A signed 64-bit integer, distinct from Float64.
    case int64(Int64)
    /// An IEEE-754 Float64, including signed zero and nonfinite values.
    case float64(Double)
    /// A Convex bytestring.
    case bytes(Data)
    /// An ordered collection of Convex values.
    case array([ConvexValue])
    /// An object whose keys retain their wire spelling, including document system fields.
    case object([String: ConvexValue])

    /// Encodes only supported Convex values, rejecting reserved object envelope keys.
    public func encodeConvex(to encoder: any Encoder) throws {
        switch self {
        case .null: try ConvexNull().encodeConvex(to: encoder)
        case .boolean(let value): try value.encodeConvex(to: encoder)
        case .string(let value): try value.encodeConvex(to: encoder)
        case .int64(let value): try value.encodeConvex(to: encoder)
        case .float64(let value): try value.encodeConvex(to: encoder)
        case .bytes(let value): try value.encodeConvex(to: encoder)
        case .array(let values): try values.encodeConvex(to: encoder)
        case .object(let fields):
            var container = encoder.container(keyedBy: ConvexCodingKey.self)
            for (key, value) in fields {
                guard !key.isEmpty, !key.hasPrefix("$") else {
                    throw EncodingError.invalidValue(
                        key,
                        .init(
                            codingPath: encoder.codingPath,
                            debugDescription: "Reserved Convex object key"
                        )
                    )
                }
                try container.encodeConvex(value, forKey: ConvexCodingKey(key))
            }
        }
    }

    /// Recognizes scalar envelopes before ordinary objects and rejects unknown envelopes.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() { return .null }
        if let value = try? scalar.decode(Bool.self) { return .boolean(value) }
        if let value = try? scalar.decode(String.self) { return .string(value) }
        if let value = try? scalar.decode(Double.self) { return .float64(value) }
        if var array = try? decoder.unkeyedContainer() {
            var values: [ConvexValue] = []
            if let count = array.count { values.reserveCapacity(count) }
            while !array.isAtEnd { values.append(try array.decodeConvex(Self.self)) }
            return .array(values)
        }
        let object = try decoder.container(keyedBy: ConvexCodingKey.self)
        let keys = object.allKeys
        if keys.contains(ConvexCodingKey("$integer")) {
            return try .int64(Int64.decodeConvex(from: decoder))
        }
        if keys.contains(ConvexCodingKey("$float")) {
            return try .float64(Double.decodeConvex(from: decoder))
        }
        if keys.contains(ConvexCodingKey("$bytes")) {
            return try .bytes(Data.decodeConvex(from: decoder))
        }
        guard !keys.contains(where: { $0.stringValue.hasPrefix("$") || $0.stringValue.isEmpty })
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown or unresolved Convex envelope"
                )
            )
        }
        var fields: [String: ConvexValue] = [:]
        fields.reserveCapacity(keys.count)
        for key in keys {
            fields[key.stringValue] = try object.decodeConvex(Self.self, forKey: key)
        }
        return .object(fields)
    }
}
