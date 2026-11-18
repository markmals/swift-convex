import ConvexNative

/// The production transport: every operation runs through the Rust Convex client.
struct NativeTransport: ConvexTransport {
    let client: NativeClient

    func call(_ kind: OperationKind, path: String, arguments: [String: String]) async throws
        -> String
    {
        do {
            switch kind {
            case .query:
                return try await client.query(path, arguments: arguments)
            case .mutation:
                return try await client.mutation(path, arguments: arguments)
            case .action:
                return try await client.action(path, arguments: arguments)
            }
        } catch let error as NativeError {
            throw ConvexClientError(error)
        }
    }

    func subscribe(
        path: String,
        arguments: [String: String],
        onUpdate: @escaping @Sendable (_ payload: String) -> Void,
        onError: @escaping @Sendable (_ message: String, _ data: String?) -> Void
    ) async throws -> any ConvexTransportSubscription {
        do {
            return try await client.subscribe(
                path,
                arguments: arguments,
                onUpdate: onUpdate,
                onError: onError
            )
        } catch let error as NativeError {
            throw ConvexClientError(error)
        }
    }

    func setAuthenticationProvider(
        _ fetchToken: (@Sendable (_ forceRefresh: Bool) async throws -> String?)?
    ) async throws {
        do {
            try await client.setAuthenticationProvider(fetchToken)
        } catch let error as NativeError {
            throw ConvexClientError(error)
        }
    }
}

extension NativeSubscription: ConvexTransportSubscription {}

extension ConvexClientError {
    init(_ error: NativeError) {
        switch error {
        case .internalError(let message):
            self = .runtime(message: message)
        case .serverError(let message):
            self = .server(message: message)
        case .applicationError(let data):
            self = .application(ConvexApplicationError(message: nil, encodedData: data))
        }
    }
}

extension ConvexConnectionState {
    init(_ state: NativeConnectionState) {
        switch state {
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        }
    }
}
