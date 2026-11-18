import Testing

@testable import Convex

@Suite("Client query events", .timeLimit(.minutes(1)))
struct ClientQueryEventsTests {
    typealias Fixtures = ClientFixtures

    @Test func creatingEventsDoesNotSubscribe() {
        let transport = Fixtures.Transport()
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))

        events.cancel()

        #expect(transport.subscriptions.isEmpty)
    }

    @Test func valueDeliveredBeforeRegistrationReturnsIsNotDropped() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { $0.emit(#""cached""#) })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        defer { events.cancel() }
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == "cached")

        let subscription = try #require(transport.subscriptions.only)
        let expectedArguments = ["channel": try ConvexCodec.encode("general")]
        #expect(subscription.path == "messages:latest")
        #expect(subscription.arguments == expectedArguments)
    }

    @Test func slowConsumerReceivesNewestSnapshotInOrder() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { subscription in
            subscription.emit(#""first""#)
            subscription.emit(#""second""#)
            subscription.emit(#""third""#)
        })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        defer { events.cancel() }
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == "third")
        let subscription = try #require(transport.subscriptions.only)
        subscription.emit(#""fourth""#)
        #expect(try await iterator.next() == "fourth")
    }

    @Test func terminalErrorFollowsEarlierValueAndCancelsSubscription() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { subscription in
            subscription.emit(#""latest""#)
            subscription.fail(message: "Uncaught ConvexError", data: #""rate limited""#)
        })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == "latest")
        let error = await #expect(throws: ConvexClientError.self) { try await iterator.next() }

        guard case .application(let failure)? = error else {
            Issue.record("Expected an application error, got \(String(describing: error))")
            return
        }
        #expect(failure.message == "Uncaught ConvexError")
        #expect(try failure.data(as: String.self) == "rate limited")
        let subscription = try #require(transport.subscriptions.only)
        await subscription.waitForCancellation()
        #expect(transport.subscriptions.only?.cancelCount == 1)
        #expect(try await iterator.next() == nil)
    }

    @Test func serverErrorEndsSequence() async throws {
        let transport = Fixtures.Transport()
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        let consumer = Task {
            var iterator = events.makeAsyncIterator()
            return try await iterator.next()
        }
        let subscription = await transport.nextRegistration()

        subscription.fail(message: "Server Error")

        let error = await #expect(throws: ConvexClientError.self) { try await consumer.value }
        guard case .server(let message)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(message == "Server Error")
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
    }

    @Test func cancellationReturnsBeforeRegistrationAndCancelsLateHandle() async throws {
        let gate = Fixtures.Gate()
        let transport = Fixtures.Transport(beforeReturningSubscription: { _ in await gate.wait() })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        let consumer = Task {
            var iterator = events.makeAsyncIterator()
            return try await iterator.next()
        }
        let subscription = await transport.nextRegistration()

        events.cancel()
        subscription.emit(#""late""#)
        #expect(subscription.cancelCount == 0)
        #expect(try await consumer.value == nil)

        gate.open()
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
    }

    @Test func taskCancellationEndsIterationAndCancelsSubscription() async throws {
        let transport = Fixtures.Transport()
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        let consumer = Task {
            var iterator = events.makeAsyncIterator()
            return try await iterator.next()
        }
        let subscription = await transport.nextRegistration()

        consumer.cancel()

        #expect(try await consumer.value == nil)
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
    }

    @Test func explicitCancellationDiscardsBufferedAndLateResults() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { $0.emit(#""first""#) })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == "first")
        let subscription = try #require(transport.subscriptions.only)

        subscription.emit(#""buffered""#)
        events.cancel()
        subscription.emit(#""late""#)
        subscription.fail(message: "late failure")

        #expect(try await iterator.next() == nil)
        await subscription.waitForCancellation()
        #expect(subscription.cancelCount == 1)
        events.cancel()
        #expect(subscription.cancelCount == 1)
    }

    @Test func releasingIteratorCancelsSubscription() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { $0.emit(#""first""#) })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))

        do {
            var iterator = events.makeAsyncIterator()
            #expect(try await iterator.next() == "first")
            #expect(transport.subscriptions.only?.cancelCount == 0)
        }

        let subscription = try #require(transport.subscriptions.only)
        await subscription.waitForCancellation()
        #expect(transport.subscriptions.only?.cancelCount == 1)
    }

    @Test func secondIteratorIsRejectedWithoutSubscribing() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { $0.emit(#""first""#) })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        defer { events.cancel() }
        var first = events.makeAsyncIterator()
        var second = events.makeAsyncIterator()

        let error = await #expect(throws: ConvexClientError.self) { try await second.next() }
        guard case .eventsAlreadyIterated? = error else {
            Issue.record("Expected a repeated-iteration error, got \(String(describing: error))")
            return
        }
        #expect(try await second.next() == nil)
        #expect(transport.subscriptions.isEmpty)
        #expect(try await first.next() == "first")
        #expect(transport.subscriptions.count == 1)
    }

    @Test func undecodableSnapshotEndsSequenceWithEndpoint() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { $0.emit("42") })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        var iterator = events.makeAsyncIterator()

        let error = await #expect(throws: ConvexClientError.self) { try await iterator.next() }

        guard case .decoding(let functionPath, _)? = error else {
            Issue.record("Expected a decoding failure, got \(String(describing: error))")
            return
        }
        #expect(functionPath == "messages:latest")
        let subscription = try #require(transport.subscriptions.only)
        await subscription.waitForCancellation()
        #expect(transport.subscriptions.only?.cancelCount == 1)
        #expect(try await iterator.next() == nil)
    }

    @Test func unencodableArgumentsFailFirstIterationWithoutSubscribing() async throws {
        let transport = Fixtures.Transport()
        let events = transport.makeClient().events(for: Fixtures.UnencodableQuery())
        var iterator = events.makeAsyncIterator()

        let error = await #expect(throws: ConvexClientError.self) { try await iterator.next() }

        guard case .encoding(let functionPath, _)? = error else {
            Issue.record("Expected an encoding failure, got \(String(describing: error))")
            return
        }
        #expect(functionPath == "messages:broken")
        #expect(transport.subscriptions.isEmpty)
    }

    @Test func registrationFailureEndsSequence() async throws {
        let transport = Fixtures.Transport(beforeReturningSubscription: { _ in
            throw ConvexClientError.runtime(message: "invalid arguments")
        })
        let events = transport.makeClient().events(for: Fixtures.LatestMessage(channel: "general"))
        var iterator = events.makeAsyncIterator()

        let error = await #expect(throws: ConvexClientError.self) { try await iterator.next() }

        guard case .runtime(let message)? = error else {
            Issue.record("Expected a runtime failure, got \(String(describing: error))")
            return
        }
        #expect(message == "invalid arguments")
        #expect(try await iterator.next() == nil)
    }
}

extension Array {
    /// The sole element, or `nil` when the array is empty or has several elements.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
