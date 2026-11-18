import Observation
import Testing

@testable import Convex

@Suite("Observable client status", .timeLimit(.minutes(1)))
struct ObservationClientStatusTests {
    typealias Fixtures = ClientFixtures

    @Test func connectionChangesNotifyObservers() async {
        let transport = Fixtures.Transport()
        let client = transport.makeClient()
        #expect(client.connectionState == .connecting)

        await confirmation("connection change observed") { observed in
            withObservationTracking {
                _ = client.connectionState
            } onChange: {
                observed()
            }
            transport.reportConnection(.connected)
        }

        #expect(client.connectionState == .connected)
    }

    @Test func providerChangesNotifyObservers() async throws {
        let transport = Fixtures.Transport()
        let client = transport.makeClient()

        try await confirmation("provider change observed") { observed in
            withObservationTracking {
                _ = client.authenticationProviderState
            } onChange: {
                observed()
            }
            try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "token" })
        }

        #expect(client.authenticationProviderState == .installed)
    }

    @Test func connectionTrackingIgnoresProviderChanges() async throws {
        let transport = Fixtures.Transport()
        let client = transport.makeClient()

        try await confirmation("connection observer notified", expectedCount: 0) { observed in
            withObservationTracking {
                _ = client.connectionState
            } onChange: {
                observed()
            }
            try await client.setAuthenticationProvider(Fixtures.TokenProvider { _ in "token" })
        }
    }
}
