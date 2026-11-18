import ConvexNative
public import Foundation
public import Observation

/// A connection to one Convex deployment, driven by the official Rust Convex client.
///
/// Every operation accepts a generated request value, so the backend function, its
/// arguments, and its result type are fixed at compile time. The client is safe to share
/// across tasks and actors; all operations share one native connection.
///
/// Reading ``connectionState`` or ``authenticationProviderState`` participates in
/// Observation tracking. Those properties change on runtime threads, not the main actor.
public final class ConvexClient: Observable, Sendable {
    private let transport: any ConvexTransport
    private let status: ClientStatus
    private let authentication: AuthenticationInstaller

    /// Creates a client for `deploymentURL`, such as `https://happy-otter-123.convex.cloud`.
    ///
    /// Nothing connects until the first operation; an invalid URL fails that operation.
    public convenience init(deploymentURL: URL) {
        self.init { onConnectionChange in
            NativeTransport(
                client: NativeClient(
                    deploymentURL: deploymentURL.absoluteString,
                    onConnectionChange: { onConnectionChange(ConvexConnectionState($0)) }
                )
            )
        }
    }

    init(
        makeTransport: (_ onConnectionChange: @escaping @Sendable (ConvexConnectionState) -> Void)
            -> any ConvexTransport
    ) {
        let status = ClientStatus()
        self.status = status
        transport = makeTransport { status.setConnectionState($0) }
        authentication = AuthenticationInstaller(status: status)
    }

    // MARK: - One-shot operations

    /// Runs a query once and returns its current result.
    ///
    /// A `nil` result of a nullable query is a successful value. Use ``query(_:)`` or
    /// ``events(for:)`` to follow later changes.
    public func queryOnce<Request: QueryRequest>(_ request: Request) async throws -> Request.Output
    {
        try await perform(request, as: .query)
    }

    /// Runs a mutation and returns its result.
    ///
    /// Canceling the calling task stops the wait, not the mutation: the server may still
    /// commit it.
    @discardableResult
    public func mutate<Request: MutationRequest>(_ request: Request) async throws -> Request.Output
    {
        try await perform(request, as: .mutation)
    }

    /// Runs an action and returns its result.
    ///
    /// Actions are never retried automatically. Canceling the calling task stops the wait,
    /// not the action: its side effects may still happen.
    @discardableResult
    public func callAction<Request: ActionRequest>(_ request: Request) async throws
        -> Request.Output
    {
        try await perform(request, as: .action)
    }

    private func perform<Request: ConvexRequest>(
        _ request: Request,
        as kind: OperationKind
    ) async throws -> Request.Output {
        let arguments = try ClientCoding.arguments(of: request)
        let payload = try await transport.call(
            kind,
            path: Request.functionPath,
            arguments: arguments
        )
        return try ClientCoding.decode(
            Request.Output.self,
            from: payload,
            functionPath: Request.functionPath
        )
    }

    // MARK: - Live queries

    /// Returns a sequence of the query's results, starting when it is first iterated.
    ///
    /// Each call creates an independent subscription for a single consumer.
    public func events<Request: QueryRequest>(for request: Request) -> QueryEvents<Request.Output> {
        let transport = transport
        return QueryEvents(functionPath: Request.functionPath) { onUpdate, onError in
            try await transport.subscribe(
                path: Request.functionPath,
                arguments: ClientCoding.arguments(of: request),
                onUpdate: onUpdate,
                onError: onError
            )
        }
    }

    /// Returns an observable model that follows the query's result on the main actor.
    ///
    /// The model subscribes immediately and keeps its subscription until it is canceled or
    /// deinitialized. Keep it in stable state, such as a view's `@State`, rather than
    /// recreating it in `body`; create a new model when the request changes.
    @MainActor
    public func query<Request: QueryRequest>(_ request: Request) -> Query<Request.Output> {
        Query(events: events(for: request))
    }

    // MARK: - Status and authentication

    /// The runtime's current connection state.
    public var connectionState: ConvexConnectionState {
        status.connectionState
    }

    /// What the installed authentication provider last reported.
    ///
    /// This reflects token lookups only; a supplied token can still be rejected by the server.
    public var authenticationProviderState: ConvexAuthenticationProviderState {
        status.authenticationProviderState
    }

    /// Installs the provider that supplies identity tokens, or signs out when `provider` is `nil`.
    ///
    /// Replacements apply in call order and complete even if the calling task is canceled.
    /// After a replacement starts, token lookups still running on the previous provider are
    /// discarded instead of restoring its session. Returning means the runtime accepted the
    /// change, not that the deployment accepted a token.
    public func setAuthenticationProvider(_ provider: (any ConvexAuthenticationProvider)?)
        async throws
    {
        try await authentication.install(provider, using: transport)
    }
}

/// Converts requests and results at the native boundary, attributing failures to the endpoint.
enum ClientCoding {
    static func arguments<Request: ConvexRequest>(of request: Request) throws -> [String: String] {
        do {
            return try request.encodeArguments()
        } catch {
            throw ConvexClientError.encoding(functionPath: Request.functionPath, underlying: error)
        }
    }

    static func decode<Output: ConvexValueCodable>(
        _ type: Output.Type,
        from payload: String,
        functionPath: String
    ) throws -> Output {
        do {
            return try ConvexCodec.decode(type, from: payload)
        } catch {
            throw ConvexClientError.decoding(functionPath: functionPath, underlying: error)
        }
    }
}
