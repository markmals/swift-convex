import Testing

@testable import Convex

@Suite("Client authentication", .timeLimit(.minutes(1)))
struct ClientAuthenticationTests {
    typealias Fixtures = ClientFixtures

    @Test func providerSuppliesTokensAndReportsOutcomes() async throws {
        let provider = Fixtures.TokenProvider { forceRefresh in
            guard forceRefresh else { return nil }
            return "token"
        }
        let transport = Fixtures.Transport()
        let client = transport.makeClient()
        #expect(client.authenticationProviderState == .notInstalled)

        try await client.setAuthenticationProvider(provider)
        #expect(client.authenticationProviderState == .installed)
        let lookup = try #require(transport.tokenLookups.only ?? nil)

        #expect(try await lookup(true) == "token")
        #expect(client.authenticationProviderState == .tokenProvided)
        #expect(try await lookup(false) == nil)
        #expect(client.authenticationProviderState == .noToken)
        #expect(provider.forceRefreshRequests == [true, false])
    }

    @Test func providerFailureIsRethrownAndReported() async throws {
        let transport = Fixtures.Transport()
        let client = transport.makeClient()
        try await client.setAuthenticationProvider(
            Fixtures.TokenProvider { _ in
                throw Fixtures.Failure.tokenUnavailable
            }
        )
        let lookup = try #require(transport.tokenLookups.only ?? nil)

        await #expect(throws: Fixtures.Failure.tokenUnavailable) { try await lookup(false) }

        #expect(client.authenticationProviderState == .tokenFetchFailed)
    }

    @Test func clearingProviderSignsOut() async throws {
        let transport = Fixtures.Transport()
        let client = transport.makeClient()
        try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "token" })

        try await client.setAuthenticationProvider(nil)

        #expect(transport.tokenLookups.count == 2)
        #expect(transport.tokenLookups.last.map { $0 == nil } == true)
        #expect(client.authenticationProviderState == .notInstalled)
    }

    @Test func replacedProviderCannotSupplyTokens() async throws {
        let transport = Fixtures.Transport()
        let client = transport.makeClient()
        try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "old" })
        let retired = try #require(transport.tokenLookups.last ?? nil)
        try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "new" })
        let current = try #require(transport.tokenLookups.last ?? nil)

        await #expect(throws: CancellationError.self) { try await retired(false) }
        #expect(client.authenticationProviderState == .installed)
        #expect(try await current(false) == "new")
        #expect(client.authenticationProviderState == .tokenProvided)
    }

    @Test func lateTokenFromReplacedProviderIsDiscarded() async throws {
        let entered = Fixtures.AsyncQueue<Bool>()
        let gate = Fixtures.Gate()
        let transport = Fixtures.Transport()
        let client = transport.makeClient()
        try await client.setAuthenticationProvider(
            Fixtures.TokenProvider { forceRefresh in
                entered.push(forceRefresh)
                await gate.wait()
                return "stale"
            }
        )
        let retired = try #require(transport.tokenLookups.last ?? nil)
        let pendingLookup = Task { try await retired(false) }
        _ = await entered.next()

        try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "fresh" })
        gate.open()

        await #expect(throws: CancellationError.self) { try await pendingLookup.value }
        #expect(client.authenticationProviderState == .installed)
    }

    @Test func failedInstallationLeavesNoActiveProvider() async throws {
        let transport = Fixtures.Transport(beforeInstallingProvider: {
            throw Fixtures.Failure.installationRejected
        })
        let client = transport.makeClient()

        await #expect(throws: Fixtures.Failure.installationRejected) {
            try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "token" })
        }

        #expect(client.authenticationProviderState == .notInstalled)
        #expect(transport.tokenLookups.isEmpty)
    }
}

extension Array {
    /// The sole element, or `nil` when the array is empty or has several elements.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
