/// Couples a backend function's identity, arguments, and fixed output type.
public protocol ConvexRequest: Sendable {
    /// The only output type this request may decode.
    associatedtype Output: ConvexValueCodable

    /// The exact backend address, independent of generated Swift names.
    static var functionPath: String { get }

    /// Encodes present arguments as Convex JSON; omitted arguments have no map entry.
    func encodeArguments() throws -> [String: String]
}

/// Restricts query observation and one-shot reads to generated query requests.
public protocol QueryRequest: ConvexRequest {}

/// Restricts transactional mutation calls to generated mutation requests.
public protocol MutationRequest: ConvexRequest {}

/// Restricts action execution to generated action requests.
public protocol ActionRequest: ConvexRequest {}
