import Observation
import os

@testable import Convex

/// Deterministic doubles for the native transport; every wait is event-driven.
enum ClientFixtures {
    struct LatestMessage: QueryRequest {
        typealias Output = String
        static let functionPath = "messages:latest"
        var channel: String

        func encodeArguments() throws -> [String: String] {
            ["channel": try ConvexCodec.encode(channel)]
        }
    }

    struct OptionalMessage: QueryRequest {
        typealias Output = String?
        static let functionPath = "messages:find"
        var channel: String

        func encodeArguments() throws -> [String: String] {
            ["channel": try ConvexCodec.encode(channel)]
        }
    }

    struct SendMessage: MutationRequest {
        typealias Output = String
        static let functionPath = "messages:send"
        var channel: String
        var body: String

        func encodeArguments() throws -> [String: String] {
            ["body": try ConvexCodec.encode(body), "channel": try ConvexCodec.encode(channel)]
        }
    }

    struct DeliverNotification: ActionRequest {
        typealias Output = Bool
        static let functionPath = "notifications:deliver"
        var messageID: String

        func encodeArguments() throws -> [String: String] {
            ["messageId": try ConvexCodec.encode(messageID)]
        }
    }

    struct UnencodableQuery: QueryRequest {
        typealias Output = String
        static let functionPath = "messages:broken"

        func encodeArguments() throws -> [String: String] {
            throw Failure.unencodable
        }
    }

    enum Failure: Error, Equatable {
        case unencodable
        case unexpectedCall
        case tokenUnavailable
        case installationRejected
    }

    struct Call: Sendable, Equatable {
        var kind: OperationKind
        var path: String
        var arguments: [String: String]
    }

    typealias TokenLookup = @Sendable (_ forceRefresh: Bool) async throws -> String?

    final class Transport: ConvexTransport {
        typealias Responder = @Sendable (Call) async throws -> String
        typealias RegistrationHook = @Sendable (Subscription) async throws -> Void

        private struct State: Sendable {
            var calls: [Call] = []
            var subscriptions: [Subscription] = []
            var connectionHandler: (@Sendable (ConvexConnectionState) -> Void)?
            var tokenLookups: [TokenLookup?] = []
        }

        private let respond: Responder
        private let beforeReturningSubscription: RegistrationHook
        private let beforeInstallingProvider: @Sendable () async throws -> Void
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let registrations = AsyncQueue<Subscription>()

        // Runs the registration hook after installing callbacks but before returning the handle.
        init(
            respond: @escaping Responder = { _ in throw Failure.unexpectedCall },
            beforeReturningSubscription: @escaping RegistrationHook = { _ in },
            beforeInstallingProvider: @escaping @Sendable () async throws -> Void = {}
        ) {
            self.respond = respond
            self.beforeReturningSubscription = beforeReturningSubscription
            self.beforeInstallingProvider = beforeInstallingProvider
        }

        func makeClient() -> ConvexClient {
            ConvexClient { onConnectionChange in
                self.state.withLock { $0.connectionHandler = onConnectionChange }
                return self
            }
        }

        var calls: [Call] { state.withLock { $0.calls } }
        var subscriptions: [Subscription] { state.withLock { $0.subscriptions } }
        var tokenLookups: [TokenLookup?] { state.withLock { $0.tokenLookups } }

        /// Waits until the client starts registering its next subscription.
        func nextRegistration() async -> Subscription {
            await registrations.next()
        }

        func reportConnection(_ connection: ConvexConnectionState) {
            state.withLock { $0.connectionHandler }?(connection)
        }

        func call(_ kind: OperationKind, path: String, arguments: [String: String]) async throws
            -> String
        {
            let call = Call(kind: kind, path: path, arguments: arguments)
            state.withLock { $0.calls.append(call) }
            return try await respond(call)
        }

        func subscribe(
            path: String,
            arguments: [String: String],
            onUpdate: @escaping @Sendable (_ payload: String) -> Void,
            onError: @escaping @Sendable (_ message: String, _ data: String?) -> Void
        ) async throws -> any ConvexTransportSubscription {
            let subscription = Subscription(
                path: path,
                arguments: arguments,
                onUpdate: onUpdate,
                onError: onError
            )
            state.withLock { $0.subscriptions.append(subscription) }
            registrations.push(subscription)
            try await beforeReturningSubscription(subscription)
            return subscription
        }

        func setAuthenticationProvider(_ fetchToken: TokenLookup?) async throws {
            try await beforeInstallingProvider()
            state.withLock { $0.tokenLookups.append(fetchToken) }
        }
    }

    /// A registered subscription; its callbacks keep firing after cancellation, like late
    /// native deliveries.
    final class Subscription: ConvexTransportSubscription {
        let path: String
        let arguments: [String: String]
        private let onUpdate: @Sendable (String) -> Void
        private let onError: @Sendable (String, String?) -> Void
        private let cancellations = OSAllocatedUnfairLock(initialState: 0)
        private let cancellation = Gate()

        init(
            path: String,
            arguments: [String: String],
            onUpdate: @escaping @Sendable (String) -> Void,
            onError: @escaping @Sendable (String, String?) -> Void
        ) {
            self.path = path
            self.arguments = arguments
            self.onUpdate = onUpdate
            self.onError = onError
        }

        var cancelCount: Int { cancellations.withLock { $0 } }

        func cancel() {
            cancellations.withLock { $0 += 1 }
            cancellation.open()
        }

        func waitForCancellation() async {
            await cancellation.wait()
        }

        func emit(_ payload: String) {
            onUpdate(payload)
        }

        func fail(message: String, data: String? = nil) {
            onError(message, data)
        }
    }

    final class TokenProvider: ConvexAuthenticationProvider {
        private let lookup: @Sendable (_ forceRefresh: Bool) async throws -> String?
        private let requests = OSAllocatedUnfairLock<[Bool]>(initialState: [])

        init(lookup: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String?) {
            self.lookup = lookup
        }

        var forceRefreshRequests: [Bool] { requests.withLock { $0 } }

        func token(forceRefresh: Bool) async throws -> String? {
            requests.withLock { $0.append(forceRefresh) }
            return try await lookup(forceRefresh)
        }
    }

    /// Suspends callers until opened.
    final class Gate: Sendable {
        private struct State: Sendable {
            var isOpen = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isOpen = state.withLock { (state: inout State) -> Bool in
                    guard !state.isOpen else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if isOpen { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock {
                (state: inout State) -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    /// An unbounded FIFO that hands each element to exactly one `next()` caller.
    final class AsyncQueue<Element: Sendable>: Sendable {
        private struct State: Sendable {
            var buffer: [Element] = []
            var waiters: [CheckedContinuation<Element, Never>] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func push(_ element: Element) {
            let waiter = state.withLock {
                (state: inout State) -> CheckedContinuation<Element, Never>? in
                guard !state.waiters.isEmpty else {
                    state.buffer.append(element)
                    return nil
                }
                return state.waiters.removeFirst()
            }
            waiter?.resume(returning: element)
        }

        func next() async -> Element {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element, Never>) in
                let element = state.withLock { (state: inout State) -> Element? in
                    guard !state.buffer.isEmpty else {
                        state.waiters.append(continuation)
                        return nil
                    }
                    return state.buffer.removeFirst()
                }
                if let element { continuation.resume(returning: element) }
            }
        }
    }
}

extension QueryState {
    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    var loadedValue: Output? {
        if case .value(let output) = self { output } else { nil }
    }

    var failure: (any Error)? {
        if case .failed(let error) = self { error } else { nil }
    }
}

/// Runs `trigger` with Observation tracking installed on `query.state`, then returns the
/// state after the next tracked change.
@MainActor
func stateChange<Output: ConvexValueCodable>(
    of query: Query<Output>,
    after trigger: () -> Void = {}
) async -> QueryState<Output> {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        withObservationTracking {
            _ = query.state
        } onChange: {
            continuation.resume()
        }
        trigger()
    }
    return query.state
}
