use tokio::sync::watch;

/// A one-way cancellation flag shared between a Swift task and one native operation.
///
/// Swift creates a signal per operation and calls [`CancellationSignal::cancel`] from its task
/// cancellation handler. The operation then completes with [`crate::RuntimeError::Cancelled`]
/// and drops its native work. Cancelling more than once, or after completion, has no effect.
#[derive(Debug, uniffi::Object)]
pub struct CancellationSignal {
    sender: watch::Sender<bool>,
}

#[uniffi::export]
impl CancellationSignal {
    /// Creates a signal that has not been cancelled.
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            sender: watch::Sender::new(false),
        }
    }

    /// Requests cancellation. Idempotent and safe from any thread.
    pub fn cancel(&self) {
        self.sender.send_replace(true);
    }
}

impl CancellationSignal {
    pub(crate) fn subscribe(&self) -> watch::Receiver<bool> {
        self.sender.subscribe()
    }
}

/// Resolves once `flag` becomes `true`.
///
/// Returns `Err` only if every sender was dropped without setting the flag, in which case
/// callers must keep waiting on their other branch instead of treating it as cancellation.
pub(crate) async fn raised(
    flag: &mut watch::Receiver<bool>,
) -> Result<(), watch::error::RecvError> {
    flag.wait_for(|raised| *raised).await.map(|_| ())
}
