import Convex
import Foundation
import Observation
import Testing

@MainActor
@Suite(
    "Live generated Convex client",
    .enabled(if: ProcessInfo.processInfo.environment["CONVEX_INTEGRATION_URL"] != nil),
    .timeLimit(.minutes(1))
)
struct LiveBackendTests {
    @Test func observableQueryAndSequenceFollowRealMutations() async throws {
        let client = try liveClient()
        let channelID = try await client.mutate(LiveAPI.Channels.Create(name: "swift-\(UUID())"))
        let request = LiveAPI.Messages.List(channelID: channelID)
        let query = client.query(request)
        defer { query.cancel() }
        let initial = try await queryValue(query) { $0.isEmpty }
        #expect(initial.isEmpty)

        let events = client.events(for: request)
        defer { events.cancel() }
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        let messageID = try await client.mutate(
            LiveAPI.Messages.Send(body: "Swift live proof", channelID: channelID)
        )
        let messages = try await queryValue(query) { $0.contains { $0.id == messageID } }
        let message = try #require(messages.first { $0.id == messageID })
        #expect(message.body == "Swift live proof")
        #expect(message.channelID == channelID)
        #expect(message.editedAt == nil)
        #expect(message.committedAt > 0)
        let event = try #require(try await iterator.next())
        #expect(event.contains { $0.id == messageID })

        let summary = try await client.callAction(
            LiveAPI.Actions.ChannelSummary(channelID: channelID)
        )
        #expect(summary.channelID == channelID)
        #expect(summary.messageCount == 1)
        let channel = try #require(
            try await client.queryOnce(LiveAPI.Channels.Get(channelID: channelID))
        )
        #expect(channel.messageCount == 1)
        let updated = try await client.mutate(
            LiveAPI.Channels.SetTopic(channelID: channelID, topic: nil)
        )
        #expect(updated == ConvexNull())
    }

    @Test func successfulNullIsObservableValue() async throws {
        let client = try liveClient()
        let query = client.query(LiveAPI.Auth.Whoami())
        defer { query.cancel() }
        let identity = try await queryValue(query) { _ in true }
        #expect(identity == nil)
        #expect(try await client.queryOnce(LiveAPI.Auth.Whoami()) == nil)
    }
}

func liveClient() throws -> ConvexClient {
    let endpoint = try #require(ProcessInfo.processInfo.environment["CONVEX_INTEGRATION_URL"])
    let url = try #require(URL(string: endpoint))
    try #require(
        url.host == "127.0.0.1" || url.host == "localhost",
        "Integration fixtures must use a disposable loopback deployment"
    )
    return ConvexClient(deploymentURL: url)
}

@MainActor
func queryValue<Output: ConvexValueCodable>(
    _ query: Query<Output>,
    matching predicate: (Output) -> Bool
) async throws -> Output {
    while true {
        switch query.state {
        case .value(let value) where predicate(value): return value
        case .failed(let error): throw error
        default: break
        }
        let change = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            withObservationTracking {
                _ = query.state
            } onChange: {
                continuation.yield(())
                continuation.finish()
            }
        }
        for await _ in change { break }
        try Task.checkCancellation()
    }
}
