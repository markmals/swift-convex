import Testing

@testable import Convex

@MainActor
@Suite("Observable queries", .timeLimit(.minutes(1)))
struct ObservationQueryTests {
    typealias Fixtures = ClientFixtures

    @Test func liveResultsReplaceLoadingThroughObservation() async throws {
        let transport = Fixtures.Transport()
        let query = transport.makeClient().observe(Fixtures.LatestMessage(channel: "general"))
        defer { query.cancel() }
        #expect(query.state.isLoading)
        let subscription = await transport.nextRegistration()

        let first = await stateChange(of: query) { subscription.emit(#""hello""#) }
        #expect(first.loadedValue == "hello")

        let second = await stateChange(of: query) { subscription.emit(#""goodbye""#) }
        #expect(second.loadedValue == "goodbye")
        #expect(subscription.path == "messages:latest")
    }

    @Test func cachedValueDeliveredDuringRegistrationReachesModel() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { $0.emit(#""cached""#) })
        let query = transport.makeClient().observe(Fixtures.LatestMessage(channel: "general"))
        defer { query.cancel() }

        let state = await stateChange(of: query)

        #expect(state.loadedValue == "cached")
    }

    @Test func nullResultIsValueNotLoading() async throws {
        let transport = Fixtures.Transport()
        let query = transport.makeClient().observe(Fixtures.OptionalMessage(channel: "general"))
        defer { query.cancel() }
        #expect(query.state.isLoading)
        let subscription = await transport.nextRegistration()

        let state = await stateChange(of: query) { subscription.emit("null") }

        #expect(!state.isLoading)
        #expect(state.loadedValue == .some(nil))
    }

    @Test func serverErrorBecomesFailedState() async throws {
        let transport = Fixtures.Transport()
        let query = transport.makeClient().observe(Fixtures.LatestMessage(channel: "general"))
        let subscription = await transport.nextRegistration()
        _ = await stateChange(of: query) { subscription.emit(#""hello""#) }

        let state = await stateChange(of: query) { subscription.fail(message: "Server Error") }

        guard case .server(let message)? = state.failure as? ConvexClientError else {
            Issue.record("Expected a server failure, got \(state)")
            return
        }
        #expect(message == "Server Error")
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
    }

    @Test func undecodableResultBecomesFailedState() async throws {
        let transport = Fixtures.Transport()
        let query = transport.makeClient().observe(Fixtures.LatestMessage(channel: "general"))
        let subscription = await transport.nextRegistration()

        let state = await stateChange(of: query) { subscription.emit("42") }

        guard case .decoding(let functionPath, _)? = state.failure as? ConvexClientError else {
            Issue.record("Expected a decoding failure, got \(state)")
            return
        }
        #expect(functionPath == "messages:latest")
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
    }

    @Test func explicitCancelEndsSubscriptionAndKeepsLastValue() async throws {
        let transport = Fixtures.Transport()
        let query = transport.makeClient().observe(Fixtures.LatestMessage(channel: "general"))
        let subscription = await transport.nextRegistration()
        _ = await stateChange(of: query) { subscription.emit(#""hello""#) }

        query.cancel()
        query.cancel()

        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
        #expect(query.state.loadedValue == "hello")
    }

    @Test func releasingModelCancelsSubscription() async throws {
        let transport = Fixtures.Transport()
        var query: Query<String>? = transport.makeClient().observe(
            Fixtures.LatestMessage(channel: "general")
        )
        weak let released = query
        let subscription = await transport.nextRegistration()
        _ = try await stateChange(of: #require(query)) { subscription.emit(#""hello""#) }
        #expect(subscription.cancelCount == 0)

        query = nil

        #expect(released == nil)
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
    }

    @Test func modelIsReleasedBeforeItsConsumerStarts() {
        let transport = Fixtures.Transport()
        var query: Query<String>? = transport.makeClient().observe(
            Fixtures.LatestMessage(channel: "general")
        )
        weak let released = query

        query = nil

        #expect(released == nil)
    }
}
