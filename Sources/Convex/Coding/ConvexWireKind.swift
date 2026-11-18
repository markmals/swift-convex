import Foundation

/// Discriminates union cases without allocating a dynamic tree of the entire value.
public enum ConvexWireKind: Sendable {
    /// An explicit null.
    case null
    /// A boolean scalar.
    case boolean
    /// A string scalar, including an unvalidated document identifier.
    case string
    /// A JSON number or special Float64 envelope.
    case float64
    /// A signed integer envelope.
    case int64
    /// A bytes envelope.
    case bytes
    /// An ordered collection.
    case array
    /// An object without a scalar envelope.
    case object
}

extension ConvexCodec {
    /// Inspects the outer wire kind; the selected typed decoder still validates its payload.
    public static func wireKind(from decoder: any Decoder) throws -> ConvexWireKind {
        if let object = try? decoder.container(keyedBy: ConvexCodingKey.self) {
            let keys = object.allKeys
            if keys.count == 1 {
                switch keys[0].stringValue {
                case "$integer": return .int64
                case "$float": return .float64
                case "$bytes": return .bytes
                default: break
                }
            }
            guard !keys.contains(where: { $0.stringValue.hasPrefix("$") }) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown Convex envelope"
                    )
                )
            }
            return .object
        }
        if (try? decoder.unkeyedContainer()) != nil { return .array }
        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() { return .null }
        if (try? scalar.decode(Bool.self)) != nil { return .boolean }
        if (try? scalar.decode(Double.self)) != nil { return .float64 }
        if (try? scalar.decode(String.self)) != nil { return .string }
        throw DecodingError.dataCorruptedError(
            in: scalar,
            debugDescription: "Unknown Convex wire kind"
        )
    }
}
