/// The WebSocket state reported by the Rust Convex client.
///
/// The runtime connects on the client's first operation and reconnects on its own, so
/// `connecting` covers the time before that operation, the first connection, and recovery
/// after a drop. A connection says nothing about whether the server accepted a token.
public enum ConvexConnectionState: Sendable, Hashable {
    case connecting
    case connected
}
