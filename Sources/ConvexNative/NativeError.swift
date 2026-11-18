import ConvexNativeBindings

/// A failure reported by the native Convex runtime.
public enum NativeError: Error, Sendable, Equatable {
    /// The runtime, transport, or local request validation failed, as the message describes.
    case internalError(String)
    /// The deployment reported an unexpected function failure with this message.
    case serverError(String)
    /// The function threw a `ConvexError`; the value is its Convex-encoded JSON payload.
    case applicationError(String)
}

/// The native client's WebSocket connection state.
public enum NativeConnectionState: Sendable {
    /// Connecting, or reconnecting after a failure.
    case connecting
    /// Connected to the deployment.
    case connected
}

extension NativeError {
    /// Maps a bridge failure to the error ``NativeClient`` throws.
    ///
    /// Native cancellation becomes `CancellationError`. Any failure outside the bridge's error
    /// type, such as a converted Rust panic, becomes ``internalError(_:)``.
    static func translating(_ error: any Error) -> any Error {
        if error is CancellationError {
            return error
        }
        guard let runtimeError = error as? RuntimeError else {
            return NativeError.internalError(String(describing: error))
        }
        switch runtimeError {
        case .Internal(let message), .InvalidRequest(let message):
            return NativeError.internalError(message)
        case .Server(let message):
            return NativeError.serverError(message)
        case .Application(let data):
            return NativeError.applicationError(data)
        case .Cancelled:
            return CancellationError()
        }
    }
}

extension NativeConnectionState {
    init(_ state: ConnectionState) {
        switch state {
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        }
    }
}
