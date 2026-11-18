import Convex
import Foundation
import Testing

@MainActor
@Suite(
    "Live native authentication",
    .enabled(if: ProcessInfo.processInfo.environment["CONVEX_INTEGRATION_TOKEN_FILE"] != nil),
    .timeLimit(.minutes(1))
)
struct LiveAuthenticationTests {
    @Test func providerInstallationAndLogoutUpdateTheObservableIdentity() async throws {
        let tokenPath = try #require(
            ProcessInfo.processInfo.environment["CONVEX_INTEGRATION_TOKEN_FILE"]
        )
        let token = try String(contentsOf: URL(fileURLWithPath: tokenPath), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try liveClient()
        let identity = client.observe(LiveAPI.Auth.Whoami())
        defer { identity.cancel() }
        #expect(try await queryValue(identity) { $0 == nil } == nil)

        try await client.setAuthenticationProvider(FixtureIdentityProvider(value: token))
        let signedIn = try await queryValue(identity) { $0?.subject == "fixture-user" }
        #expect(signedIn?.issuer == "https://fixture.convex-contract-exporter.invalid")
        #expect(client.authenticationProviderState == .tokenProvided)

        try await client.setAuthenticationProvider(nil)
        #expect(try await queryValue(identity) { $0 == nil } == nil)
        #expect(client.authenticationProviderState == .notInstalled)
    }
}

private struct FixtureIdentityProvider: ConvexAuthenticationProvider {
    let value: String

    func token(forceRefresh: Bool) async throws -> String? { value }
}
