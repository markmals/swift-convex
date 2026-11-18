import ConvexNativeBindings

/// A connection to one Convex deployment through the official `convex` Rust client.
///
/// Every operation shares one native client and WebSocket. Nothing connects until the first
/// operation. Arguments are a map from argument name to Convex-encoded JSON; an absent key is an
/// omitted argument. Results and error payloads are Convex-encoded JSON as well. Malformed
/// paths or arguments throw ``NativeError/internalError(_:)`` without contacting the deployment.
///
/// The client is immutable after initialization; the native runtime serializes its own state,
/// so the class is safely `Sendable`. Releasing the last reference shuts the native runtime down
/// without blocking. Each ``NativeSubscription`` keeps its client alive until it is cancelled.
public final class NativeClient: Sendable {
    private let runtime: RuntimeClient

    /// Creates a client for `deploymentURL` without connecting.
    ///
    /// An invalid URL is reported by the first operation as ``NativeError/internalError(_:)``.
    /// `onConnectionChange` receives each WebSocket state change, in order, on a native runtime
    /// thread once the first operation has started the connection. It must return promptly.
    public init(
        deploymentURL: String,
        onConnectionChange: @escaping @Sendable (NativeConnectionState) -> Void
    ) {
        runtime = RuntimeClient(
            deploymentUrl: deploymentURL,
            connectionObserver: ConnectionStateRelay(onConnectionChange: onConnectionChange)
        )
    }

    /// Runs the query at `path` once and returns its Convex-encoded result.
    ///
    /// Task cancellation stops the native request and throws `CancellationError`.
    public func query(_ path: String, arguments: [String: String]) async throws -> String {
        try await perform { cancellation in
            try await runtime.query(name: path, args: arguments, cancellation: cancellation)
        }
    }

    /// Runs the mutation at `path` and returns its Convex-encoded result.
    ///
    /// Task cancellation stops waiting and throws `CancellationError`; the mutation may still
    /// execute on the deployment.
    public func mutation(_ path: String, arguments: [String: String]) async throws -> String {
        try await perform { cancellation in
            try await runtime.mutation(name: path, args: arguments, cancellation: cancellation)
        }
    }

    /// Runs the action at `path` and returns its Convex-encoded result.
    ///
    /// Task cancellation stops waiting and throws `CancellationError`; the action may still
    /// execute on the deployment.
    public func action(_ path: String, arguments: [String: String]) async throws -> String {
        try await perform { cancellation in
            try await runtime.action(name: path, args: arguments, cancellation: cancellation)
        }
    }

    /// Subscribes to the query at `path`.
    ///
    /// Callbacks are installed before registration, so `onUpdate` can receive the first result
    /// before this method returns. They run serially, in the order the Convex client produced
    /// them, on a native runtime thread, and must return promptly. `onUpdate` receives each
    /// Convex-encoded result. `onError` receives a function failure's message and, for a
    /// `ConvexError`, its Convex-encoded payload; delivery continues after it unless cancelled.
    ///
    /// If registration fails or the task is cancelled first, the native subscription is removed,
    /// both callbacks are released, and this method throws. Otherwise the returned subscription
    /// owns it.
    public func subscribe(
        _ path: String,
        arguments: [String: String],
        onUpdate: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String, String?) -> Void
    ) async throws -> NativeSubscription {
        let delivery = SubscriptionDelivery(onUpdate: onUpdate, onError: onError)
        let handle: SubscriptionHandle
        do {
            handle = try await perform { cancellation in
                try await runtime.subscribe(
                    name: path,
                    args: arguments,
                    observer: delivery,
                    cancellation: cancellation
                )
            }
        } catch {
            delivery.close()
            throw error
        }
        let subscription = NativeSubscription(handle: handle, delivery: delivery, client: self)
        if Task.isCancelled {
            subscription.cancel()
            throw CancellationError()
        }
        return subscription
    }

    /// Installs the authentication token provider, or logs out when `provider` is `nil`.
    ///
    /// The provider receives `forceRefresh == false` when installed and `true` after each
    /// reconnect, and returns a token or `nil` for no authentication. While it runs, the native
    /// client waits for it. A thrown error counts as unauthenticated. Replacing or clearing the
    /// provider cancels its pending call, and a retired provider's token is never applied.
    /// Calls are applied in order. This returns once the change is queued; it does not prove
    /// the deployment accepted the token.
    public func setAuthenticationProvider(
        _ provider: (@Sendable (Bool) async throws -> String?)?
    ) async throws {
        do {
            try await runtime.setAuthProvider(
                provider: provider.map { AuthenticationProviderBridge(fetchToken: $0) }
            )
        } catch {
            throw NativeError.translating(error)
        }
    }

    /// Runs `operation` with a cancellation signal tied to the current task.
    private func perform<Output: Sendable>(
        _ operation: (CancellationSignal) async throws -> Output
    ) async throws -> Output {
        let cancellation = CancellationSignal()
        do {
            return try await withTaskCancellationHandler {
                try await operation(cancellation)
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            throw NativeError.translating(error)
        }
    }
}
