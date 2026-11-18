import os

/// Live results of one query, as a throwing asynchronous sequence.
///
/// Creating the sequence performs no network work; its iterator's first `next()` registers
/// the subscription. Results are snapshots, not an event log: a slow consumer receives only
/// the newest result that arrived since its previous `next()`. A server or decoding error
/// ends the sequence.
///
/// The sequence supports one iterator. Task cancellation, releasing the iterator, a terminal
/// error, or ``cancel()`` ends the subscription. A retained sequence can outlive an early
/// loop exit, so use `defer { events.cancel() }` when teardown must be deterministic.
public struct QueryEvents<Output: ConvexValueCodable>: AsyncSequence, Sendable {
    /// The generated request's fixed output type.
    public typealias Element = Output

    private let core: QueryEventsCore<Output>

    init(functionPath: String, subscribe: @escaping QueryEventsCore<Output>.Subscribe) {
        core = QueryEventsCore(functionPath: functionPath, subscribe: subscribe)
    }

    /// Returns the sequence's only consuming iterator; any later iterator throws
    /// ``ConvexClientError/eventsAlreadyIterated``.
    public func makeAsyncIterator() -> Iterator {
        Iterator(core: core, isFirst: core.claimIterator())
    }

    /// Ends the subscription and discards undelivered results; repeated calls have no effect.
    ///
    /// A pending `next()` returns `nil`. Results that arrive afterward are dropped.
    public func cancel() {
        core.cancel()
    }

    /// Delivers successive query results.
    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let lifetime: IteratorLifetime<Output>?
        private var rejectionPending: Bool

        init(core: QueryEventsCore<Output>, isFirst: Bool) {
            lifetime = isFirst ? IteratorLifetime(core: core) : nil
            rejectionPending = !isFirst
        }

        /// Returns the newest unseen result, or `nil` once the subscription has been canceled.
        ///
        /// Awaiting from more than one task at once is a programming error.
        public mutating func next() async throws -> Output? {
            guard let lifetime else {
                guard rejectionPending else { return nil }
                rejectionPending = false
                throw ConvexClientError.eventsAlreadyIterated
            }
            return try await lifetime.core.next()
        }
    }
}

/// Cancels the subscription when the last copy of its iterator is released.
private final class IteratorLifetime<Output: ConvexValueCodable>: Sendable {
    let core: QueryEventsCore<Output>

    init(core: QueryEventsCore<Output>) {
        self.core = core
    }

    deinit {
        core.cancel()
    }
}

/// Owns buffering, registration, and teardown for one ``QueryEvents`` sequence.
final class QueryEventsCore<Output: ConvexValueCodable>: Sendable {
    typealias Subscribe =
        @Sendable (
            _ onUpdate: @escaping @Sendable (_ payload: String) -> Void,
            _ onError: @escaping @Sendable (_ message: String, _ data: String?) -> Void
        ) async throws -> any ConvexTransportSubscription

    private let functionPath: String
    private let subscribe: Subscribe
    private let state = OSAllocatedUnfairLock(initialState: QueryEventsState())

    init(functionPath: String, subscribe: @escaping Subscribe) {
        self.functionPath = functionPath
        self.subscribe = subscribe
    }

    func claimIterator() -> Bool {
        state.withLock { $0.claimIterator() }
    }

    func cancel() {
        state.withLock { $0.finish() }?.run()
    }

    func next() async throws -> Output? {
        try await withTaskCancellationHandler {
            try await nextOutput()
        } onCancel: {
            cancel()
        }
    }

    private func nextOutput() async throws -> Output? {
        if state.withLock({ $0.beginRegistration() }) {
            startRegistration()
        }
        while true {
            switch state.withLock({ $0.step() }) {
            case .deliver(let payload):
                return try decode(payload)
            case .fail(let error):
                throw error
            case .end:
                return nil
            case .wait:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if state.withLock({ $0.park(continuation) }) {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func startRegistration() {
        let subscribe = subscribe
        let registration = Task { [weak self] in
            do {
                let subscription = try await subscribe(
                    { [weak self] payload in self?.receive(payload) },
                    { [weak self] message, data in
                        self?.terminate(
                            with: ConvexClientError(subscriptionMessage: message, data: data)
                        )
                    }
                )
                guard let self else {
                    subscription.cancel()
                    return
                }
                self.state.withLock { $0.activate(subscription) }?.cancel()
            } catch {
                self?.terminate(with: error)
            }
        }
        if state.withLock({ $0.installRegistrationTask(registration) }) {
            registration.cancel()
        }
    }

    private func decode(_ payload: String) throws -> Output? {
        let output: Output
        do {
            output = try ClientCoding.decode(Output.self, from: payload, functionPath: functionPath)
        } catch {
            guard let teardown = state.withLock({ $0.finish() }) else { return nil }
            teardown.run()
            throw error
        }
        // Cancellation during decoding wins over the result.
        return state.withLock { $0.isFinished } ? nil : output
    }

    private func receive(_ payload: String) {
        state.withLock { $0.buffer(payload) }.run()
    }

    private func terminate(with error: any Error) {
        state.withLock { $0.terminate(with: error) }.run()
    }
}

/// Work decided under the lock and performed after releasing it.
private struct QueryEventsEffects: Sendable {
    var subscriptionToCancel: (any ConvexTransportSubscription)?
    var registrationToCancel: Task<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?

    func run() {
        registrationToCancel?.cancel()
        subscriptionToCancel?.cancel()
        waiter?.resume()
    }
}

private struct QueryEventsState: Sendable {
    enum Registration: Sendable {
        case idle
        case pending
        case active(any ConvexTransportSubscription)
        /// No handle may be kept; one that arrives later is canceled on arrival.
        case closed
    }

    enum Step: Sendable {
        case deliver(String)
        case fail(any Error)
        case end
        case wait
    }

    private var iteratorClaimed = false
    private var registration = Registration.idle
    private var registrationTask: Task<Void, Never>?
    private(set) var isFinished = false
    private var latestPayload: String?
    /// Delivered after `latestPayload`, preserving callback order.
    private var terminalError: (any Error)?
    private var waiter: CheckedContinuation<Void, Never>?

    mutating func claimIterator() -> Bool {
        defer { iteratorClaimed = true }
        return !iteratorClaimed
    }

    mutating func beginRegistration() -> Bool {
        guard !isFinished, case .idle = registration else { return false }
        registration = .pending
        return true
    }

    mutating func installRegistrationTask(_ task: Task<Void, Never>) -> Bool {
        switch registration {
        case .pending:
            registrationTask = task
            return false
        case .closed:
            return true
        case .idle, .active:
            return false
        }
    }

    /// Returns a handle that arrived after the sequence closed; the caller must cancel it.
    mutating func activate(
        _ subscription: any ConvexTransportSubscription
    ) -> (any ConvexTransportSubscription)? {
        registrationTask = nil
        guard case .pending = registration else { return subscription }
        registration = .active(subscription)
        return nil
    }

    mutating func buffer(_ payload: String) -> QueryEventsEffects {
        guard !isFinished, terminalError == nil else { return QueryEventsEffects() }
        latestPayload = payload
        return QueryEventsEffects(waiter: takeWaiter())
    }

    mutating func terminate(with error: any Error) -> QueryEventsEffects {
        guard !isFinished, terminalError == nil else { return QueryEventsEffects() }
        terminalError = error
        return QueryEventsEffects(
            subscriptionToCancel: close(),
            registrationToCancel: takeRegistrationTask(),
            waiter: takeWaiter()
        )
    }

    /// Returns `nil` when the sequence had already finished.
    mutating func finish() -> QueryEventsEffects? {
        guard !isFinished else { return nil }
        isFinished = true
        latestPayload = nil
        terminalError = nil
        return QueryEventsEffects(
            subscriptionToCancel: close(),
            registrationToCancel: takeRegistrationTask(),
            waiter: takeWaiter()
        )
    }

    mutating func step() -> Step {
        if isFinished { return .end }
        if let payload = latestPayload {
            latestPayload = nil
            return .deliver(payload)
        }
        if let error = terminalError {
            terminalError = nil
            isFinished = true
            return .fail(error)
        }
        return .wait
    }

    /// Returns `true` when the consumer should resume immediately instead of waiting.
    mutating func park(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        if isFinished || latestPayload != nil || terminalError != nil { return true }
        precondition(
            waiter == nil,
            "A QueryEvents iterator was awaited from more than one task at once."
        )
        waiter = continuation
        return false
    }

    private mutating func close() -> (any ConvexTransportSubscription)? {
        defer { registration = .closed }
        guard case .active(let subscription) = registration else { return nil }
        return subscription
    }

    private mutating func takeRegistrationTask() -> Task<Void, Never>? {
        defer { registrationTask = nil }
        return registrationTask
    }

    private mutating func takeWaiter() -> CheckedContinuation<Void, Never>? {
        defer { waiter = nil }
        return waiter
    }
}
