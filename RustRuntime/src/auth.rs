//! Authentication tokens from a foreign provider.
//!
//! A token fetch is a synchronous foreign call that starts work and a Rust-owned
//! [`TokenRequest`] the provider completes later. Foreign async trait methods would be simpler,
//! but UniFFI's generated Swift for them does not compile under Swift 6 strict concurrency.

use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex, PoisonError},
};

use convex::{AuthTokenFetcher, AuthenticationToken};
use tokio::sync::{oneshot, watch};

use crate::{cancellation::raised, RuntimeError};

/// Supplies authentication tokens to the Convex client.
///
/// The client fetches a token when the provider is installed (`force_refresh == false`) and
/// after every WebSocket reconnect (`force_refresh == true`). While a fetch is pending, the
/// Convex client's worker waits for it.
#[uniffi::export(with_foreign)]
pub trait AuthTokenProvider: Send + Sync {
    /// Starts fetching a token and returns immediately.
    ///
    /// Complete `request` with the token, or `None` for no authentication, once available.
    /// Stop working once [`TokenRequest::finished`] resolves; the runtime then no longer needs
    /// the result, for example because the provider was replaced. An `Err` counts as `None`.
    fn fetch_token(
        &self,
        force_refresh: bool,
        request: Arc<TokenRequest>,
    ) -> Result<(), RuntimeError>;
}

/// One pending token fetch, completed at most once by the foreign provider.
#[derive(Debug, uniffi::Object)]
pub struct TokenRequest {
    result: Mutex<Option<oneshot::Sender<Option<String>>>>,
    finished: watch::Sender<bool>,
}

#[uniffi::export]
impl TokenRequest {
    /// Delivers `token` (`None` for no authentication). Only the first call has an effect, and
    /// none after [`TokenRequest::finished`] resolves.
    pub fn complete(&self, token: Option<String>) {
        let sender = self
            .result
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(sender) = sender {
            let _ = sender.send(token);
        }
    }

    /// Resolves once the runtime stops waiting for this request: after it is completed and
    /// consumed, or when the fetch is abandoned because the provider was retired or the client
    /// shut down.
    pub async fn finished(&self) {
        let mut finished = self.finished.subscribe();
        // The sender lives in `self`, so this resolves only when the flag is raised.
        let _ = raised(&mut finished).await;
    }
}

impl TokenRequest {
    fn new() -> (Arc<Self>, oneshot::Receiver<Option<String>>) {
        let (sender, receiver) = oneshot::channel();
        let request = Arc::new(Self {
            result: Mutex::new(Some(sender)),
            finished: watch::Sender::new(false),
        });
        (request, receiver)
    }

    fn finish(&self) {
        self.result
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        self.finished.send_replace(true);
    }
}

/// Finishes a request when its fetch completes or is dropped.
struct FinishOnDrop(Arc<TokenRequest>);

impl Drop for FinishOnDrop {
    fn drop(&mut self) {
        self.0.finish();
    }
}

/// The future type the `convex` crate's [`AuthTokenFetcher`] returns.
type TokenFuture = Pin<Box<dyn Future<Output = anyhow::Result<AuthenticationToken>> + Send>>;

/// Adapts a foreign provider to the `convex` crate's fetcher.
///
/// Once `retired` is raised, pending and future fetches yield no authentication, so a replaced
/// provider can never restore its session. Provider failures also yield no authentication:
/// the `convex` crate would otherwise keep the previous identity after a failed fetch.
pub(crate) fn token_fetcher(
    provider: Arc<dyn AuthTokenProvider>,
    retired: watch::Receiver<bool>,
) -> AuthTokenFetcher {
    Box::new(move |force_refresh: bool| -> TokenFuture {
        let provider = Arc::clone(&provider);
        let mut retired = retired.clone();
        Box::pin(async move {
            if *retired.borrow_and_update() {
                return Ok(AuthenticationToken::None);
            }
            let (request, result) = TokenRequest::new();
            let _finish = FinishOnDrop(Arc::clone(&request));
            if provider.fetch_token(force_refresh, request).is_err() {
                return Ok(AuthenticationToken::None);
            }
            let token = tokio::select! {
                biased;
                Ok(()) = raised(&mut retired) => None,
                delivered = result => delivered.ok().flatten(),
            };
            Ok(match token {
                Some(token) => AuthenticationToken::User(token),
                None => AuthenticationToken::None,
            })
        })
    })
}
