use std::any::Any;

use tokio::task::JoinError;

/// A failure reported across the native boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RuntimeError {
    /// The runtime, transport, or Convex client failed locally.
    #[error("{message}")]
    Internal { message: String },
    /// The deployment reported an unexpected function failure.
    #[error("{message}")]
    Server { message: String },
    /// A Convex function threw a `ConvexError`; `data` is its Convex-encoded JSON payload.
    #[error("Convex application error")]
    Application { data: String },
    /// The function path or an argument was not valid Convex input. Nothing was sent.
    #[error("{message}")]
    InvalidRequest { message: String },
    /// The caller's cancellation signal fired before the operation completed.
    #[error("The operation was cancelled")]
    Cancelled,
}

impl RuntimeError {
    pub(crate) fn internal(error: impl std::fmt::Display) -> Self {
        Self::Internal {
            message: error.to_string(),
        }
    }

    pub(crate) fn from_join(error: JoinError) -> Self {
        if error.is_panic() {
            let detail = panic_detail(error.into_panic());
            Self::Internal {
                message: format!("The native runtime task panicked: {detail}"),
            }
        } else {
            Self::Internal {
                message: "The native runtime stopped before the operation completed".to_owned(),
            }
        }
    }
}

/// Converts failures inside foreign (Swift) callback implementations, such as a stale handle,
/// into an error instead of a Rust panic.
impl From<uniffi::UnexpectedUniFFICallbackError> for RuntimeError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Internal {
            message: error.reason,
        }
    }
}

fn panic_detail(payload: Box<dyn Any + Send>) -> String {
    match payload.downcast::<String>() {
        Ok(message) => *message,
        Err(payload) => match payload.downcast::<&'static str>() {
            Ok(message) => (*message).to_owned(),
            Err(_) => "unknown panic payload".to_owned(),
        },
    }
}
