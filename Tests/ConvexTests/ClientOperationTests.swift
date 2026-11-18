import Testing

@testable import Convex

@Suite("Client one-shot operations", .timeLimit(.minutes(1)))
struct ClientOperationTests {
    typealias Fixtures = ClientFixtures

    @Test func fetchRunsNativeQueryAndDecodesOutput() async throws {
        let transport = Fixtures.Transport(respond: { _ in #""hello""# })
        let client = transport.makeClient()

        let output = try await client.fetch(Fixtures.LatestMessage(channel: "general"))

        #expect(output == "hello")
        let expectedArguments = ["channel": try ConvexCodec.encode("general")]
        #expect(
            transport.calls == [
                Fixtures.Call(kind: .query, path: "messages:latest", arguments: expectedArguments)
            ]
        )
        #expect(transport.subscriptions.isEmpty)
    }

    @Test func mutationAndActionRunTheirOwnOperationKinds() async throws {
        let transport = Fixtures.Transport(respond: { call in
            switch call.kind {
            case .mutation: #""message-1""#
            case .action: "true"
            case .query: throw Fixtures.Failure.unexpectedCall
            }
        })
        let client = transport.makeClient()

        let messageID = try await client.execute(
            mutation: Fixtures.SendMessage(channel: "general", body: "Hi")
        )
        let delivered = try await client.execute(
            action: Fixtures.DeliverNotification(messageID: messageID)
        )

        #expect(messageID == "message-1")
        #expect(delivered)
        #expect(transport.calls.map(\.kind) == [.mutation, .action])
        #expect(transport.calls.map(\.path) == ["messages:send", "notifications:deliver"])
        let deliveryArguments = ["messageId": try ConvexCodec.encode("message-1")]
        #expect(transport.calls.last?.arguments == deliveryArguments)
    }

    @Test func nullResultIsSuccessfulNil() async throws {
        let transport = Fixtures.Transport(respond: { _ in "null" })
        let client = transport.makeClient()

        let output = try await client.fetch(Fixtures.OptionalMessage(channel: "general"))

        #expect(output == nil)
    }

    @Test func mismatchedResultReportsEndpoint() async throws {
        let transport = Fixtures.Transport(respond: { _ in "42" })
        let client = transport.makeClient()

        let error = await #expect(throws: ConvexClientError.self) {
            try await client.fetch(Fixtures.LatestMessage(channel: "general"))
        }

        guard case .decoding(let functionPath, let underlying)? = error else {
            Issue.record("Expected a decoding failure, got \(String(describing: error))")
            return
        }
        #expect(functionPath == "messages:latest")
        #expect(underlying is DecodingError)
    }

    @Test func unencodableArgumentsAreNeverSent() async throws {
        let transport = Fixtures.Transport(respond: { _ in #""unused""# })
        let client = transport.makeClient()

        let error = await #expect(throws: ConvexClientError.self) {
            try await client.fetch(Fixtures.UnencodableQuery())
        }

        guard case .encoding(let functionPath, let underlying)? = error else {
            Issue.record("Expected an encoding failure, got \(String(describing: error))")
            return
        }
        #expect(functionPath == "messages:broken")
        #expect(underlying as? Fixtures.Failure == .unencodable)
        #expect(transport.calls.isEmpty)
    }

    @Test func applicationErrorPayloadSurvives() async throws {
        let transport = Fixtures.Transport(respond: { _ in
            throw ConvexClientError.application(
                ConvexApplicationError(message: nil, encodedData: #""rate limited""#)
            )
        })
        let client = transport.makeClient()

        let error = await #expect(throws: ConvexClientError.self) {
            try await client.execute(mutation: Fixtures.SendMessage(channel: "general", body: "Hi"))
        }

        guard case .application(let failure)? = error else {
            Issue.record("Expected an application error, got \(String(describing: error))")
            return
        }
        #expect(try failure.data(as: String.self) == "rate limited")
    }
}
