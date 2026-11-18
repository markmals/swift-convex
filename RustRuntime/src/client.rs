use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, Mutex, PoisonError},
};

use convex::{
    ConvexClient, ConvexClientBuilder, FunctionResult, QuerySubscription, WebSocketState,
};
use futures::StreamExt;
use tokio::{
    runtime::{Handle, Runtime},
    sync::{mpsc, oneshot, watch, OnceCell},
    task::{AbortHandle, JoinHandle},
};

use crate::{
    auth::token_fetcher,
    cancellation::raised,
    values::{encode_value, function_output, FunctionRequest},
    AuthTokenProvider, CancellationSignal, ConnectionObserver, QueryObserver, RuntimeError,
};

/// Identifies this client to the deployment's `Convex-Client` header.
const CLIENT_ID: &str = concat!("swift-convex-", env!("CARGO_PKG_VERSION"));

/// Connection-state changes the bridge buffers. The `convex` crate drops a state change when
/// this buffer is full, so it is sized well above the two states a reconnect produces.
const CONNECTION_STATE_BUFFER: usize = 64;

/// A Convex deployment client that owns a Tokio runtime and one shared [`ConvexClient`].
///
/// Nothing starts until the first operation: the runtime, the `convex` client, and its
/// WebSocket are created lazily, as in upstream convex-mobile. Dropping the last reference shuts
/// the runtime down without blocking, which ends every subscription and pending operation.
#[derive(uniffi::Object)]
pub struct RuntimeClient {
    shared: Arc<Shared>,
    runtime: Mutex<Option<Runtime>>,
}

/// State shared with runtime tasks. It never owns the runtime, so a task can never drop it.
struct Shared {
    deployment_url: String,
    connection_observer: Option<Arc<dyn ConnectionObserver>>,
    client: OnceCell<ConvexClient>,
    /// Retirement flag of the installed authentication provider. The lock orders provider
    /// replacement with the requests sent to the Convex worker.
    installed_provider: tokio::sync::Mutex<Option<watch::Sender<bool>>>,
}

#[uniffi::export]
impl RuntimeClient {
    /// Creates a client for `deployment_url` without connecting.
    ///
    /// An invalid URL is reported by the first operation. `connection_observer`, when present,
    /// receives every connection-state change after the client connects.
    #[uniffi::constructor]
    pub fn new(
        deployment_url: String,
        connection_observer: Option<Arc<dyn ConnectionObserver>>,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                deployment_url,
                connection_observer,
                client: OnceCell::new(),
                installed_provider: tokio::sync::Mutex::new(None),
            }),
            runtime: Mutex::new(None),
        }
    }

    /// Runs query `name` once and returns its Convex-encoded result.
    ///
    /// The result is the first value of a temporary subscription, which is removed afterwards.
    pub async fn query(
        &self,
        name: String,
        args: HashMap<String, String>,
        cancellation: Arc<CancellationSignal>,
    ) -> Result<String, RuntimeError> {
        let request = FunctionRequest::parse(name, args)?;
        let shared = Arc::clone(&self.shared);
        self.run(&cancellation, async move {
            let mut client = shared.connected_client().await?;
            let mut subscription = client
                .subscribe(&request.path, request.arguments)
                .await
                .map_err(RuntimeError::internal)?;
            match subscription.next().await {
                Some(result) => function_output(result),
                None => Err(RuntimeError::internal(
                    "The Convex client stopped before the query produced a result",
                )),
            }
        })
        .await
    }

    /// Runs mutation `name` and returns its Convex-encoded result.
    ///
    /// Cancellation stops waiting for the result; the mutation may still run on the server.
    pub async fn mutation(
        &self,
        name: String,
        args: HashMap<String, String>,
        cancellation: Arc<CancellationSignal>,
    ) -> Result<String, RuntimeError> {
        let request = FunctionRequest::parse(name, args)?;
        let shared = Arc::clone(&self.shared);
        self.run(&cancellation, async move {
            let mut client = shared.connected_client().await?;
            let result = client
                .mutation(&request.path, request.arguments)
                .await
                .map_err(RuntimeError::internal)?;
            function_output(result)
        })
        .await
    }

    /// Runs action `name` and returns its Convex-encoded result.
    ///
    /// Cancellation stops waiting for the result; the action may still run on the server.
    pub async fn action(
        &self,
        name: String,
        args: HashMap<String, String>,
        cancellation: Arc<CancellationSignal>,
    ) -> Result<String, RuntimeError> {
        let request = FunctionRequest::parse(name, args)?;
        let shared = Arc::clone(&self.shared);
        self.run(&cancellation, async move {
            let mut client = shared.connected_client().await?;
            let result = client
                .action(&request.path, request.arguments)
                .await
                .map_err(RuntimeError::internal)?;
            function_output(result)
        })
        .await
    }

    /// Subscribes to query `name`, delivering every result to `observer` in order.
    ///
    /// The observer is installed before registration, so it can receive the first result before
    /// this call returns. If `cancellation` fires first, or registration fails, the subscription
    /// is removed and the observer released. Otherwise the returned handle owns it.
    pub async fn subscribe(
        &self,
        name: String,
        args: HashMap<String, String>,
        observer: Arc<dyn QueryObserver>,
        cancellation: Arc<CancellationSignal>,
    ) -> Result<Arc<SubscriptionHandle>, RuntimeError> {
        let request = FunctionRequest::parse(name, args)?;
        let mut cancelled = cancellation.subscribe();
        if *cancelled.borrow_and_update() {
            return Err(RuntimeError::Cancelled);
        }
        let shared = Arc::clone(&self.shared);
        let (registered_sender, registered) = oneshot::channel();
        let task = self.handle()?.spawn(async move {
            let registration = async {
                let mut client = shared.connected_client().await?;
                client
                    .subscribe(&request.path, request.arguments)
                    .await
                    .map_err(RuntimeError::internal)
            }
            .await;
            match registration {
                Ok(subscription) => {
                    if registered_sender.send(Ok(())).is_ok() {
                        forward(subscription, observer).await;
                    }
                }
                Err(error) => {
                    let _ = registered_sender.send(Err(error));
                }
            }
        });
        // Dropping this handle on any early return below aborts the task, which unsubscribes.
        let handle = SubscriptionHandle {
            task: task.abort_handle(),
        };
        tokio::select! {
            biased;
            Ok(()) = raised(&mut cancelled) => Err(RuntimeError::Cancelled),
            outcome = registered => match outcome {
                Ok(Ok(())) => Ok(Arc::new(handle)),
                Ok(Err(error)) => Err(error),
                Err(_) => Err(RuntimeError::internal(
                    "The subscription task ended before registration completed",
                )),
            },
        }
    }

    /// Installs `provider` as the authentication source, or logs out when it is `None`.
    ///
    /// Replacement is serialized. A replaced provider is retired first: its pending fetch is
    /// dropped and any later result counts as unauthenticated, so it can never restore its
    /// session. A provider failure also counts as unauthenticated, rather than leaving the
    /// previous identity in place. Returns once the change is queued in the Convex client.
    pub async fn set_auth_provider(
        &self,
        provider: Option<Arc<dyn AuthTokenProvider>>,
    ) -> Result<(), RuntimeError> {
        let shared = Arc::clone(&self.shared);
        let task = self
            .handle()?
            .spawn(async move { shared.install_auth_provider(provider).await });
        task.await.map_err(RuntimeError::from_join)?
    }
}

impl RuntimeClient {
    /// Returns the runtime's handle, creating the runtime on first use.
    fn handle(&self) -> Result<Handle, RuntimeError> {
        let mut slot = self.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(runtime) = slot.as_ref() {
            return Ok(runtime.handle().clone());
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("dev.convex.swift-runtime")
            .build()
            .map_err(|error| RuntimeError::Internal {
                message: format!("Could not start the native runtime: {error}"),
            })?;
        let handle = runtime.handle().clone();
        *slot = Some(runtime);
        Ok(handle)
    }

    /// Runs `work` on the runtime until it completes or `cancellation` fires.
    ///
    /// Cancellation, or dropping the returned future, aborts `work`.
    async fn run<T>(
        &self,
        cancellation: &CancellationSignal,
        work: impl Future<Output = Result<T, RuntimeError>> + Send + 'static,
    ) -> Result<T, RuntimeError>
    where
        T: Send + 'static,
    {
        let mut cancelled = cancellation.subscribe();
        if *cancelled.borrow_and_update() {
            return Err(RuntimeError::Cancelled);
        }
        let mut task = AbortOnDrop(self.handle()?.spawn(work));
        tokio::select! {
            biased;
            Ok(()) = raised(&mut cancelled) => Err(RuntimeError::Cancelled),
            joined = &mut task.0 => joined.map_err(RuntimeError::from_join)?,
        }
    }
}

impl Drop for RuntimeClient {
    fn drop(&mut self) {
        let runtime = self
            .runtime
            .get_mut()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(runtime) = runtime {
            // Never blocks, so the last reference may be released from any thread, including
            // one inside an async context.
            runtime.shutdown_background();
        }
    }
}

impl Shared {
    /// Returns the shared `convex` client, creating it on first use. Must run on the runtime.
    async fn connected_client(&self) -> Result<ConvexClient, RuntimeError> {
        let client = self.client.get_or_try_init(|| self.connect()).await?;
        Ok(client.clone())
    }

    async fn connect(&self) -> Result<ConvexClient, RuntimeError> {
        // Fails only when a provider is already installed, which then remains in use.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut builder = ConvexClientBuilder::new(&self.deployment_url).with_client_id(CLIENT_ID);
        if let Some(observer) = &self.connection_observer {
            let observer = Arc::clone(observer);
            let (sender, mut receiver) = mpsc::channel::<WebSocketState>(CONNECTION_STATE_BUFFER);
            tokio::spawn(async move {
                while let Some(state) = receiver.recv().await {
                    if observer.on_state_change(state.into()).is_err() {
                        break;
                    }
                }
            });
            builder = builder.with_on_state_change(sender);
        }
        builder
            .build()
            .await
            .map_err(|error| RuntimeError::Internal {
                message: format!("Could not create the Convex client: {error:#}"),
            })
    }

    async fn install_auth_provider(
        &self,
        provider: Option<Arc<dyn AuthTokenProvider>>,
    ) -> Result<(), RuntimeError> {
        let mut client = self.connected_client().await?;
        let mut installed = self.installed_provider.lock().await;
        if let Some(retirement) = installed.take() {
            retirement.send_replace(true);
        }
        let fetcher = provider.map(|provider| {
            let (retirement, retired) = watch::channel(false);
            *installed = Some(retirement);
            token_fetcher(provider, retired)
        });
        client.set_auth_callback(fetcher).await;
        Ok(())
    }
}

/// Delivers subscription results until the stream ends, the task is aborted, or the observer
/// fails.
async fn forward(mut subscription: QuerySubscription, observer: Arc<dyn QueryObserver>) {
    while let Some(result) = subscription.next().await {
        let delivered = match result {
            FunctionResult::Value(value) => match encode_value(value) {
                Ok(encoded) => observer.on_update(encoded),
                Err(error) => observer.on_error(error.to_string(), None),
            },
            FunctionResult::ErrorMessage(message) => observer.on_error(message, None),
            FunctionResult::ConvexError(error) => match encode_value(error.data) {
                Ok(data) => observer.on_error(error.message, Some(data)),
                Err(encoding) => observer.on_error(encoding.to_string(), None),
            },
        };
        if delivered.is_err() {
            return;
        }
    }
    let _ = observer.on_error(
        "The Convex client stopped delivering results for this subscription".to_owned(),
        None,
    );
}

/// Owns one subscription. Cancelling or dropping it removes the subscription and releases its
/// observer.
#[derive(Debug, uniffi::Object)]
pub struct SubscriptionHandle {
    task: AbortHandle,
}

#[uniffi::export]
impl SubscriptionHandle {
    /// Stops delivery and unsubscribes. Idempotent, non-blocking, and safe from any thread,
    /// including from inside the observer. A callback already running may finish.
    pub fn cancel(&self) {
        self.task.abort();
    }
}

impl Drop for SubscriptionHandle {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Aborts a spawned task when the awaiting future is dropped.
struct AbortOnDrop<T>(JoinHandle<T>);

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}
