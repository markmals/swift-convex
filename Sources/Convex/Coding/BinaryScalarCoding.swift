public import Foundation

private func encodeEnvelope(_ bytes: Data, key: String, to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: ConvexCodingKey.self)
    try container.encode(bytes.base64EncodedString(), forKey: ConvexCodingKey(key))
}

private func decodeEnvelope(key: String, from decoder: any Decoder, byteCount: Int? = nil) throws
    -> Data
{
    let container = try decoder.container(keyedBy: ConvexCodingKey.self)
    let codingKey = ConvexCodingKey(key)
    let keys = container.allKeys
    guard keys.count == 1, keys.first == codingKey else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a single \(key) envelope"
            )
        )
    }
    let encoded = try container.decode(String.self, forKey: codingKey)
    guard let bytes = Data(base64Encoded: encoded), byteCount == nil || bytes.count == byteCount
    else {
        throw DecodingError.dataCorruptedError(
            forKey: codingKey,
            in: container,
            debugDescription: "Invalid \(key) bytes"
        )
    }
    return bytes
}

extension Int64: ConvexValueCodable {
    /// Uses the signed little-endian 64-bit Convex integer envelope.
    public func encodeConvex(to encoder: any Encoder) throws {
        var bits = littleEndian
        try withUnsafeBytes(of: &bits) {
            try encodeEnvelope(Data($0), key: "$integer", to: encoder)
        }
    }

    /// Requires an eight-byte integer envelope; JSON numbers are Float64 values.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        let bytes = try decodeEnvelope(key: "$integer", from: decoder, byteCount: 8)
        return bytes.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
    }
}

extension Double: ConvexValueCodable {
    /// Preserves signed zero and nonfinite values using Convex float envelopes.
    public func encodeConvex(to encoder: any Encoder) throws {
        if !isFinite || (isZero && sign == .minus) {
            var bits = bitPattern.littleEndian
            try withUnsafeBytes(of: &bits) {
                try encodeEnvelope(Data($0), key: "$float", to: encoder)
            }
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(self)
        }
    }

    /// Accepts ordinary Float64 JSON numbers or special-value float envelopes.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Self.self) { return value }
        let bytes = try decodeEnvelope(key: "$float", from: decoder, byteCount: 8)
        let bits = bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        let value = Double(bitPattern: bits)
        guard !value.isFinite || (value.isZero && value.sign == .minus) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Finite nonnegative-zero values must use JSON numbers"
            )
        }
        return value
    }
}

extension Data: ConvexValueCodable {
    /// Encodes bytes in Convex's $bytes envelope, not Foundation's bare base64 form.
    public func encodeConvex(to encoder: any Encoder) throws {
        try encodeEnvelope(self, key: "$bytes", to: encoder)
    }

    /// Rejects bare strings and numeric arrays as representations of bytes.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        try decodeEnvelope(key: "$bytes", from: decoder)
    }
}
