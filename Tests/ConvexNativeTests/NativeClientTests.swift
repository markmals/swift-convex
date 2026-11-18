import Darwin
import Testing
import os

@testable import ConvexNative

// The peer never answers the WebSocket handshake, so only native cancellation can finish.
@Suite(.timeLimit(.minutes(1)))
struct NativeClientTests {
    private static let promptly = Duration.seconds(5)

    @Test func malformedRequestsThrowWithoutContactingTheDeployment() async throws {
        let deployment = try SilentDeployment()
        let client = NativeClient(deploymentURL: deployment.url) { _ in }
        let invalidJSON = ["body": #"{"secret": "#]
        let invalidValue = ["count": #"{"$integer":"AQ=="}"#]

        let failures: [any Error] = await [
            failure { try await client.query("messages:list", arguments: invalidJSON) },
            failure { try await client.mutation("messages:send", arguments: invalidValue) },
            failure { try await client.action("messages:deliver", arguments: invalidJSON) },
            failure { try await client.query("../messages:list", arguments: [:]) },
            failure {
                try await client.subscribe(
                    "messages:list",
                    arguments: invalidValue,
                    onUpdate: { _ in },
                    onError: { _, _ in }
                )
            },
        ]
        for error in failures {
            guard case .internalError(let message) = error as? NativeError else {
                Issue.record("Expected NativeError.internalError, got \(error)")
                continue
            }
            #expect(!message.contains("secret"))
        }
        #expect(deployment.connectionAttempts == 0)
    }

    @Test func invalidDeploymentURLIsReportedByTheFirstOperation() async {
        let client = NativeClient(deploymentURL: "ftp://example.com") { _ in }
        let error = await failure { try await client.query("messages:list", arguments: [:]) }
        guard case .internalError(let message) = error as? NativeError else {
            Issue.record("Expected NativeError.internalError, got \(error)")
            return
        }
        #expect(message.contains("Could not create the Convex client"))
    }

    @Test(arguments: ["query", "mutation", "action", "subscribe"])
    func taskCancellationInterruptsAPendingOperation(_ operation: String) async throws {
        let deployment = try SilentDeployment()
        let client = NativeClient(deploymentURL: deployment.url) { _ in }
        let updates = Recorder<String>()
        let pending = Task {
            let arguments = ["limit": "10"]
            switch operation {
            case "query":
                _ = try await client.query("messages:list", arguments: arguments)
            case "mutation":
                _ = try await client.mutation("messages:list", arguments: arguments)
            case "action":
                _ = try await client.action("messages:list", arguments: arguments)
            default:
                _ = try await client.subscribe(
                    "messages:list",
                    arguments: arguments,
                    onUpdate: { updates.append($0) },
                    onError: { message, _ in updates.append(message) }
                )
            }
        }
        #expect(await eventually { deployment.connectionAttempts > 0 })
        try await Task.sleep(for: .milliseconds(100))

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        pending.cancel()
        let outcome = await pending.result
        #expect(clock.now - cancelledAt < Self.promptly)
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(updates.values.isEmpty)
    }

    @Test func aCancelledTaskDoesNotStartTheOperation() async throws {
        let deployment = try SilentDeployment()
        let client = NativeClient(deploymentURL: deployment.url) { _ in }
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.query("messages:list", arguments: [:])
        }
        let outcome = await pending.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(deployment.connectionAttempts == 0)
    }

    @Test func connectionStateIsReportedOnceTheFirstOperationStarts() async throws {
        let deployment = try SilentDeployment()
        let states = Recorder<NativeConnectionState>()
        let client = NativeClient(deploymentURL: deployment.url) { states.append($0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(states.values.isEmpty)
        #expect(deployment.connectionAttempts == 0)

        let pending = Task { try await client.query("messages:list", arguments: [:]) }
        #expect(await eventually { states.values.first == .connecting })
        pending.cancel()
        _ = await pending.result
    }

    @Test func clearingTheProviderCancelsItsPendingTokenRequest() async throws {
        let deployment = try SilentDeployment()
        let client = NativeClient(deploymentURL: deployment.url) { _ in }
        let requests = Recorder<Bool>()
        let cancellations = Recorder<Bool>()

        try await client.setAuthenticationProvider { forceRefresh in
            requests.append(forceRefresh)
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                cancellations.append(Task.isCancelled)
                throw error
            }
            return "retired-token"
        }
        #expect(await eventually { requests.values == [false] })
        #expect(cancellations.values.isEmpty)

        try await client.setAuthenticationProvider(nil)
        #expect(await eventually { cancellations.values == [true] })
        #expect(requests.values == [false])
    }

    @Test func closedDeliveryDropsLateCallbacksAndReleasesClosures() {
        let delivered = Recorder<String>()
        let released = Recorder<Bool>()
        let delivery: SubscriptionDelivery
        do {
            let witness = ReleaseWitness(released)
            delivery = SubscriptionDelivery(
                onUpdate: { value in
                    witness.touch()
                    delivered.append(value)
                },
                onError: { message, payload in
                    witness.touch()
                    delivered.append("\(message):\(payload ?? "nil")")
                }
            )
        }
        delivery.onUpdate(value: "1")
        delivery.onError(message: "failed", value: #"{"code":1}"#)
        #expect(released.values.isEmpty)

        delivery.close()
        #expect(released.values == [true])
        delivery.onUpdate(value: "2")
        delivery.onError(message: "late", value: nil)
        delivery.close()
        #expect(delivered.values == ["1", #"failed:{"code":1}"#])
    }
}

// MARK: - Helpers

/// Returns the error `operation` throws, or records an issue when it succeeds.
private func failure<Value>(
    _ operation: () async throws -> Value
) async -> any Error {
    do {
        _ = try await operation()
    } catch {
        return error
    }
    Issue.record("Expected the operation to throw")
    return CancellationError()
}

/// Polls `condition` until it holds or `limit` elapses.
private func eventually(
    within limit: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A thread-safe append-only log written from native callback threads.
private final class Recorder<Value: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock<[Value]>(initialState: [])

    var values: [Value] { storage.withLock { $0 } }

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }
}

/// Records its own deinitialization, proving that captured closures were released.
private final class ReleaseWitness: Sendable {
    private let released: Recorder<Bool>

    init(_ released: Recorder<Bool>) {
        self.released = released
    }

    deinit {
        released.append(true)
    }

    func touch() {}
}

// Keeps WebSocket handshakes pending while counting accepted connections.
private final class SilentDeployment: Sendable {
    struct SocketError: Error {
        let operation: String
        let code: Int32
    }

    private struct Connections: Sendable {
        var accepted: [Int32] = []
        var stopped = false
    }

    let url: String
    private let connections = OSAllocatedUnfairLock(initialState: Connections())

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketError(operation: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(listener, address, length) == 0
                    && listen(listener, 16) == 0
                    && getsockname(listener, address, &length) == 0
                    && fcntl(listener, F_SETFL, O_NONBLOCK) == 0
            }
        }
        guard listening else {
            let code = errno
            close(listener)
            throw SocketError(operation: "listen", code: code)
        }
        url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"

        // The accept loop owns every descriptor and closes them once stopped, so a descriptor
        // number can never be reused while the loop still polls it.
        let connections = connections
        Task.detached {
            while !connections.withLock({ $0.stopped }) {
                let connection = accept(listener, nil, nil)
                if connection >= 0 {
                    connections.withLock { $0.accepted.append(connection) }
                } else {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            for connection in connections.withLock({ $0.accepted }) {
                close(connection)
            }
            close(listener)
        }
    }

    deinit {
        connections.withLock { $0.stopped = true }
    }

    /// Connections accepted so far.
    var connectionAttempts: Int {
        connections.withLock { $0.accepted.count }
    }
}
