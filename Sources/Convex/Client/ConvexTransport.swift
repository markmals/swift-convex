/// The native operations that ``ConvexClient`` builds on.
///
/// Public clients always use ``NativeTransport``; this seam exists so tests can drive
/// callback ordering and registration races deterministically.
protocol ConvexTransport: Sendable {
    /// Runs a one-shot function and returns its Convex-encoded JSON result.
    func call(_ kind: OperationKind, path: String, arguments: [String: String]) async throws
        -> String

    /// Registers a live query.
    ///
    /// Callbacks may run on any thread, including before this method returns; `data` is the
    /// Convex-encoded `ConvexError` payload when the failure is an application error.
    func subscribe(
        path: String,
        arguments: [String: String],
        onUpdate: @escaping @Sendable (_ payload: String) -> Void,
        onError: @escaping @Sendable (_ message: String, _ data: String?) -> Void
    ) async throws -> any ConvexTransportSubscription

    /// Replaces the token callback; `nil` signs out.
    func setAuthenticationProvider(
        _ fetchToken: (@Sendable (_ forceRefresh: Bool) async throws -> String?)?
    ) async throws
}

/// A registered live query.
protocol ConvexTransportSubscription: Sendable {
    /// Stops callback delivery; repeated calls have no further effect.
    func cancel()
}

/// The backend function kinds that a one-shot call can run.
enum OperationKind: Sendable {
    case query
    case mutation
    case action
}
