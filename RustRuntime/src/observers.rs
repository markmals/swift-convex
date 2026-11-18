use convex::WebSocketState;

use crate::RuntimeError;

/// Receives one subscription's results, in the order the Convex client produced them.
///
/// Calls arrive serially on a runtime worker thread and must return promptly. An `Err` result,
/// such as a stale foreign handle, stops delivery for that subscription.
#[uniffi::export(with_foreign)]
pub trait QueryObserver: Send + Sync {
    /// A new successful result, as Convex-encoded JSON.
    fn on_update(&self, value: String) -> Result<(), RuntimeError>;

    /// A function failure. `value` is the Convex-encoded `ConvexError` payload, when present.
    fn on_error(&self, message: String, value: Option<String>) -> Result<(), RuntimeError>;
}

/// The Convex WebSocket's connection state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    /// Connecting or reconnecting.
    Connecting,
    /// Open and connected.
    Connected,
}

impl From<WebSocketState> for ConnectionState {
    fn from(state: WebSocketState) -> Self {
        match state {
            WebSocketState::Connecting => Self::Connecting,
            WebSocketState::Connected => Self::Connected,
        }
    }
}

/// Receives connection-state changes, in order, on a runtime worker thread.
#[uniffi::export(with_foreign)]
pub trait ConnectionObserver: Send + Sync {
    /// The connection moved to `state`.
    fn on_state_change(&self, state: ConnectionState) -> Result<(), RuntimeError>;
}
