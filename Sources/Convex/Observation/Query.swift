public import Observation

/// A query's latest result, kept current on the main actor.
///
/// Create one with ``ConvexClient/observe(_:)``. Reading ``state`` participates in Observation
/// tracking, so a SwiftUI view that reads it updates as results arrive. The model owns one
/// subscription for its whole lifetime, independent of view visibility; ``cancel()`` or
/// deinitialization ends it.
@MainActor
@Observable
public final class Query<Output: ConvexValueCodable> {
    /// The latest result; after cancellation it keeps its last value.
    public private(set) var state: QueryState<Output> = .loading

    @ObservationIgnored private let events: QueryEvents<Output>
    @ObservationIgnored private var consumer: Task<Void, Never>?

    init(events: QueryEvents<Output>) {
        self.events = events
        // Weak, so the consuming task never keeps its model alive.
        consumer = Task { [weak self] in
            do {
                for try await output in events {
                    self?.state = .value(output)
                }
            } catch {
                self?.state = .failed(error)
            }
        }
    }

    /// Idempotently stops following the query and discards later results.
    public func cancel() {
        consumer?.cancel()
        events.cancel()
    }

    deinit {
        consumer?.cancel()
        events.cancel()
    }
}

/// The phase of a ``Query``.
public enum QueryState<Output: Sendable>: Sendable {
    /// No result has arrived yet.
    case loading

    /// The latest result. A nullable query's `nil` is a value, not ``loading``.
    case value(Output)

    /// The subscription ended with this error; no further results arrive.
    case failed(any Error)
}
