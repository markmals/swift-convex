import os

/// Supplies identity tokens that Convex sends with its connection.
///
/// The application owns sign-in UI and credentials; the runtime asks the provider for a
/// token when it is installed and after each reconnect. The runtime waits for the lookup and
/// treats a thrown error as signed out.
public protocol ConvexAuthenticationProvider: Sendable {
    /// Fetches identity for installation or refresh.
    ///
    /// - Parameter forceRefresh: Whether a fresh token is required rather than a cached one.
    /// - Returns: An identity token, or nil when signed out.
    /// - Throws: Token lookup failures; the runtime signs out instead of retaining an old identity.
    func token(forceRefresh: Bool) async throws -> String?
}

/// What the installed authentication provider last reported.
///
/// These states describe the provider, never the server: a supplied token may still be
/// rejected by the deployment.
public enum ConvexAuthenticationProviderState: Sendable, Hashable {
    /// No provider is installed; functions run without an identity.
    case notInstalled

    /// A provider is installed and has not been asked for a token yet.
    case installed

    /// The provider is producing a token.
    case fetchingToken

    /// The provider's latest lookup returned a token.
    case tokenProvided

    /// The provider's latest lookup returned `nil`.
    case noToken

    /// The provider's latest lookup threw.
    case tokenFetchFailed
}

/// Applies provider replacements one at a time, in call order.
///
/// Each installation gets a generation; token lookups from a superseded generation throw
/// `CancellationError` rather than handing an old session's token to the runtime.
final class AuthenticationInstaller: Sendable {
    private let status: ClientStatus
    private let latestInstallation = OSAllocatedUnfairLock<Task<Void, any Error>?>(
        initialState: nil
    )

    init(status: ClientStatus) {
        self.status = status
    }

    func install(
        _ provider: (any ConvexAuthenticationProvider)?,
        using transport: any ConvexTransport
    ) async throws {
        let status = self.status
        let installation = latestInstallation.withLock {
            (latest: inout Task<Void, any Error>?) -> Task<Void, any Error> in
            let previous = latest
            // Unstructured so a canceled caller cannot abandon a half-applied replacement.
            let installation = Task {
                _ = await previous?.result
                try await AuthenticationInstaller.apply(provider, using: transport, status: status)
            }
            latest = installation
            return installation
        }
        try await installation.value
    }

    private static func apply(
        _ provider: (any ConvexAuthenticationProvider)?,
        using transport: any ConvexTransport,
        status: ClientStatus
    ) async throws {
        let generation = status.beginProvider(installed: provider != nil)
        let fetchToken = provider.map { provider in
            tokenLookup(provider, generation: generation, status: status)
        }
        do {
            try await transport.setAuthenticationProvider(fetchToken)
        } catch {
            // The runtime may still hold the previous callback, which this retirement disables.
            status.retireProvider(generation: generation)
            throw error
        }
    }

    private static func tokenLookup(
        _ provider: any ConvexAuthenticationProvider,
        generation: UInt64,
        status: ClientStatus
    ) -> @Sendable (_ forceRefresh: Bool) async throws -> String? {
        { forceRefresh in
            guard status.updateProvider(.fetchingToken, generation: generation) else {
                throw CancellationError()
            }
            let token: String?
            do {
                token = try await provider.token(forceRefresh: forceRefresh)
            } catch {
                _ = status.updateProvider(.tokenFetchFailed, generation: generation)
                throw error
            }
            guard
                status.updateProvider(
                    token == nil ? .noToken : .tokenProvided,
                    generation: generation
                )
            else {
                throw CancellationError()
            }
            return token
        }
    }
}
