import Foundation

/// Preserves Convex scalar envelopes and object-field presence during coding.
public protocol ConvexValueCodable: Sendable {
    /// Encodes the Convex wire representation rather than ordinary JSON defaults.
    func encodeConvex(to encoder: any Encoder) throws

    /// Rejects wire values that do not match this type's contract.
    static func decodeConvex(from decoder: any Decoder) throws -> Self
}

/// Converts typed values to and from Convex-encoded JSON at the native boundary.
public enum ConvexCodec {
    /// Produces JSON with deterministic object-key ordering and Convex scalar envelopes.
    public static func encode<Value: ConvexValueCodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(ConvexCodingBox(value)), as: UTF8.self)
    }

    /// Decodes envelopes at every nesting level, including collection elements.
    public static func decode<Value: ConvexValueCodable>(
        _ type: Value.Type,
        from json: String
    ) throws -> Value {
        try JSONDecoder().decode(ConvexCodingBox<Value>.self, from: Data(json.utf8)).value
    }
}

struct ConvexCodingBox<Value: ConvexValueCodable>: Codable {
    let value: Value

    init(_ value: Value) { self.value = value }

    init(from decoder: any Decoder) throws {
        value = try Value.decodeConvex(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try value.encodeConvex(to: encoder)
    }
}

struct ConvexCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
