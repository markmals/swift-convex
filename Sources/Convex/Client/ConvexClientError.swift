/// A failure reported by Convex or by the typed request boundary.
///
/// Error values carry server messages and payloads but never request arguments or tokens.
public enum ConvexClientError: Error, Sendable {
    /// The backend function threw a `ConvexError`; its payload is preserved.
    case application(ConvexApplicationError)

    /// The deployment reported a failure, such as an uncaught exception in the function.
    case server(message: String)

    /// The native Convex runtime failed locally, for example while validating arguments.
    case runtime(message: String)

    /// The request's arguments could not be encoded; nothing was sent.
    case encoding(functionPath: String, underlying: any Error)

    /// The result did not match the request's generated output type.
    ///
    /// `underlying` is usually a `DecodingError` whose coding path locates the mismatch.
    case decoding(functionPath: String, underlying: any Error)

    /// A ``QueryEvents`` value was iterated more than once; call ``ConvexClient/snapshots(for:)``
    /// for each independent consumer.
    case eventsAlreadyIterated
}

/// A `ConvexError` thrown by a backend function.
public struct ConvexApplicationError: Error, Sendable {
    /// The server's error message, when the runtime reports one.
    public let message: String?

    /// The error's `data`, as Convex-encoded JSON.
    public let encodedData: String

    /// Decodes the error's `data` with the same codec as function results.
    public func data<Value: ConvexValueCodable>(as type: Value.Type) throws -> Value {
        try ConvexCodec.decode(type, from: encodedData)
    }
}

extension ConvexClientError {
    /// Maps a subscription's error callback; a payload marks an application error.
    init(subscriptionMessage message: String, data: String?) {
        if let data {
            self = .application(ConvexApplicationError(message: message, encodedData: data))
        } else {
            self = .server(message: message)
        }
    }
}
