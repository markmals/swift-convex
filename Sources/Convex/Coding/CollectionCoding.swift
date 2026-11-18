import Foundation

/// Maps constrained record keys to JSON object keys without dictionary-array encoding.
public protocol ConvexObjectKey: Hashable, Sendable {
    /// The exact string sent as a record's object key.
    var convexKey: String { get }
    /// Validates a key decoded from a Convex record.
    init(convexKey: String) throws
}

extension String: ConvexObjectKey {
    /// Preserves the record key's wire spelling.
    public var convexKey: String { self }

    /// Rejects empty, non-ASCII, and reserved Convex record keys.
    public init(convexKey: String) throws {
        guard !convexKey.isEmpty,
            convexKey.first != "$", convexKey.first != "_",
            convexKey.utf8.allSatisfy({ $0 < 128 })
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid Convex record key")
            )
        }
        self = convexKey
    }
}

extension Array: ConvexValueCodable where Element: ConvexValueCodable {
    /// Retains element order and applies Convex coding to every element.
    public func encodeConvex(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in self { try container.encodeConvex(value) }
    }

    /// Rejects elements incompatible with the declared element type.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        if let count = container.count { values.reserveCapacity(count) }
        while !container.isAtEnd { values.append(try container.decodeConvex(Element.self)) }
        return values
    }
}

extension Dictionary: ConvexValueCodable where Key: ConvexObjectKey, Value: ConvexValueCodable {
    /// Encodes constrained keys as object keys, never as alternating array elements.
    public func encodeConvex(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ConvexCodingKey.self)
        for (key, value) in self {
            _ = try String(convexKey: key.convexKey)
            try container.encodeConvex(value, forKey: ConvexCodingKey(key.convexKey))
        }
    }

    /// Validates each record key and decodes every value through the Convex codec.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: ConvexCodingKey.self)
        var values: Self = [:]
        let keys = container.allKeys
        values.reserveCapacity(keys.count)
        for key in keys {
            _ = try String(convexKey: key.stringValue)
            let typedKey = try Key(convexKey: key.stringValue)
            values[typedKey] = try container.decodeConvex(Value.self, forKey: key)
        }
        return values
    }
}
