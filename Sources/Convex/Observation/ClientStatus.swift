import Observation
import os

/// Thread-safe, Observation-tracked connection and provider state for one ``ConvexClient``.
///
/// Native callbacks mutate it from runtime threads, so storage sits behind a lock and
/// notifications go through a manually driven registrar.
final class ClientStatus: Observable, Sendable {
    private struct Storage: Sendable {
        var connection = ConvexConnectionState.connecting
        var provider = ConvexAuthenticationProviderState.notInstalled
        var providerGeneration: UInt64 = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    private let registrar = ObservationRegistrar()

    var connectionState: ConvexConnectionState {
        registrar.access(self, keyPath: \.connectionState)
        return storage.withLock { $0.connection }
    }

    var authenticationProviderState: ConvexAuthenticationProviderState {
        registrar.access(self, keyPath: \.authenticationProviderState)
        return storage.withLock { $0.provider }
    }

    func setConnectionState(_ state: ConvexConnectionState) {
        registrar.withMutation(of: self, keyPath: \.connectionState) {
            storage.withLock { $0.connection = state }
        }
    }

    /// Supersedes every earlier provider and returns the new provider's generation.
    func beginProvider(installed: Bool) -> UInt64 {
        registrar.withMutation(of: self, keyPath: \.authenticationProviderState) {
            storage.withLock { (stored: inout Storage) -> UInt64 in
                stored.providerGeneration += 1
                stored.provider = installed ? .installed : .notInstalled
                return stored.providerGeneration
            }
        }
    }

    /// Records a provider outcome; returns `false`, changing nothing, once `generation` is superseded.
    func updateProvider(_ state: ConvexAuthenticationProviderState, generation: UInt64) -> Bool {
        // A superseded generation still notifies observers; they re-read an unchanged value.
        registrar.withMutation(of: self, keyPath: \.authenticationProviderState) {
            storage.withLock { (stored: inout Storage) -> Bool in
                guard stored.providerGeneration == generation else { return false }
                stored.provider = state
                return true
            }
        }
    }

    /// Disables `generation` without enabling another provider.
    func retireProvider(generation: UInt64) {
        registrar.withMutation(of: self, keyPath: \.authenticationProviderState) {
            storage.withLock { (stored: inout Storage) in
                guard stored.providerGeneration == generation else { return }
                stored.providerGeneration += 1
                stored.provider = .notInstalled
            }
        }
    }
}
