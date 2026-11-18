import ConvexNativeBindings
import os

/// A live native query subscription.
///
/// Cancelling, or releasing the last reference, unsubscribes and releases the callbacks passed
/// to ``NativeClient/subscribe(_:arguments:onUpdate:onError:)``. No callback starts after
/// ``cancel()`` returns; one already running on a native thread may still finish.
public final class NativeSubscription: Sendable {
    private let registration: OSAllocatedUnfairLock<Registration?>

    init(handle: SubscriptionHandle, delivery: SubscriptionDelivery, client: NativeClient) {
        registration = OSAllocatedUnfairLock(
            initialState: Registration(handle: handle, delivery: delivery, client: client)
        )
    }

    deinit {
        cancel()
    }

    /// Idempotently unsubscribes without blocking; callbacks already in flight may finish.
    ///
    /// Safe to call from any thread, including from inside a callback.
    public func cancel() {
        let retired = registration.withLock { current in
            let retired = current
            current = nil
            return retired
        }
        guard let retired else { return }
        retired.delivery.close()
        retired.handle.cancel()
    }
}

private struct Registration: Sendable {
    let handle: SubscriptionHandle
    let delivery: SubscriptionDelivery
    /// Keeps the native runtime alive for as long as the subscription is active.
    let client: NativeClient
}
