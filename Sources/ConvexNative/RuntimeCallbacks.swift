import ConvexNativeBindings
import os

/// Forwards one subscription's native callbacks until it is closed.
///
/// The native runtime holds this object until the subscription task ends, which can be shortly
/// after cancellation. Closing releases the caller's closures immediately and suppresses every
/// callback that has not yet read them.
final class SubscriptionDelivery: QueryObserver {
    private struct Handlers: Sendable {
        let onUpdate: @Sendable (String) -> Void
        let onError: @Sendable (String, String?) -> Void
    }

    private let handlers: OSAllocatedUnfairLock<Handlers?>

    init(
        onUpdate: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String, String?) -> Void
    ) {
        handlers = OSAllocatedUnfairLock(
            initialState: Handlers(onUpdate: onUpdate, onError: onError)
        )
    }

    func onUpdate(value: String) {
        handlers.withLock { $0 }?.onUpdate(value)
    }

    func onError(message: String, value: String?) {
        handlers.withLock { $0 }?.onError(message, value)
    }

    /// Releases registered callbacks; a callback already captured by a delivery may finish.
    func close() {
        handlers.withLock { $0 = nil }
    }
}

/// Forwards native connection-state changes to the client's callback.
final class ConnectionStateRelay: ConnectionObserver {
    private let onConnectionChange: @Sendable (NativeConnectionState) -> Void

    init(onConnectionChange: @escaping @Sendable (NativeConnectionState) -> Void) {
        self.onConnectionChange = onConnectionChange
    }

    func onStateChange(state: ConnectionState) {
        onConnectionChange(NativeConnectionState(state))
    }
}

/// Exposes a Swift token provider to the native client.
///
/// Each fetch runs in its own task and completes the native request with the token, or with
/// `nil` when the provider throws. A second task waits until the runtime no longer needs the
/// result, such as after the provider is replaced, and then cancels the fetch.
final class AuthenticationProviderBridge: AuthTokenProvider {
    private let provider: @Sendable (Bool) async throws -> String?

    init(fetchToken provider: @escaping @Sendable (Bool) async throws -> String?) {
        self.provider = provider
    }

    func fetchToken(forceRefresh: Bool, request: TokenRequest) {
        let provider = provider
        let fetch = Task {
            let token = try? await provider(forceRefresh)
            request.complete(token: token)
        }
        Task {
            await request.finished()
            fetch.cancel()
        }
    }
}
