import Foundation

/// Gives generated table markers their exact backend identity.
public protocol ConvexTable: Sendable {
    /// The table name used by the backend, before Swift naming conversion.
    static var name: String { get }
}

/// Prevents mixing IDs from different tables without claiming existence or authorization.
public struct DocumentID<Table: ConvexTable>: Hashable, ConvexValueCodable, ConvexObjectKey {
    /// The original Convex identifier string.
    public let rawValue: String

    /// Imports a stored identifier without verifying its table or existence.
    public init(uncheckedRawValue: String) { rawValue = uncheckedRawValue }

    /// Preserves the identifier when used as a constrained record key.
    public var convexKey: String { rawValue }

    /// Validates record-key syntax, without performing a remote table lookup.
    public init(convexKey: String) throws {
        rawValue = try String(convexKey: convexKey)
    }

    /// Encodes the original identifier string without a wrapper object.
    public func encodeConvex(to encoder: any Encoder) throws {
        try rawValue.encodeConvex(to: encoder)
    }

    /// Assigns the generated table brand to a wire identifier string.
    public static func decodeConvex(from decoder: any Decoder) throws -> Self {
        try Self(uncheckedRawValue: String.decodeConvex(from: decoder))
    }
}
