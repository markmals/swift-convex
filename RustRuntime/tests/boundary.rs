//! Offline boundary tests: malformed input, cancellation, connection state, and provider
//! retirement. A listener that never answers the WebSocket handshake keeps every network
//! operation pending, so only the runtime's own lifetime handling can complete them.

use std::{collections::HashMap, net::TcpListener, sync::Arc, time::Duration};

use convex_runtime::{
    AuthTokenProvider, CancellationSignal, ConnectionObserver, ConnectionState, QueryObserver,
    RuntimeClient, RuntimeError, TokenRequest,
};
use tokio::{sync::mpsc, time::timeout};

const PROMPTLY: Duration = Duration::from_secs(5);

/// Accepts TCP connections into its backlog but never responds to the HTTP upgrade.
fn unresponsive_deployment() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind a loopback port");
    let port = listener.local_addr().expect("local address").port();
    (listener, format!("http://127.0.0.1:{port}"))
}

fn arguments(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
        .collect()
}

struct IgnoredResults;

impl QueryObserver for IgnoredResults {
    fn on_update(&self, _value: String) -> Result<(), RuntimeError> {
        Ok(())
    }

    fn on_error(&self, _message: String, _value: Option<String>) -> Result<(), RuntimeError> {
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_requests_fail_without_panicking_or_connecting() {
    let client = RuntimeClient::new("http://127.0.0.1:9".to_owned(), None);
    let invalid_json = arguments(&[("body", "{\"unterminated\": ")]);
    let invalid_value = arguments(&[("count", r#"{"$integer":"AQ=="}"#)]);

    let outcomes = [
        client
            .query(
                "messages:list".to_owned(),
                invalid_json.clone(),
                Arc::new(CancellationSignal::new()),
            )
            .await
            .err(),
        client
            .mutation(
                "messages:send".to_owned(),
                invalid_value.clone(),
                Arc::new(CancellationSignal::new()),
            )
            .await
            .err(),
        client
            .action(
                "messages:deliver".to_owned(),
                invalid_json.clone(),
                Arc::new(CancellationSignal::new()),
            )
            .await
            .err(),
        client
            .query(
                "../messages:list".to_owned(),
                HashMap::new(),
                Arc::new(CancellationSignal::new()),
            )
            .await
            .err(),
        client
            .subscribe(
                "messages:list".to_owned(),
                invalid_value,
                Arc::new(IgnoredResults),
                Arc::new(CancellationSignal::new()),
            )
            .await
            .err(),
    ];
    for outcome in outcomes {
        assert!(
            matches!(outcome, Some(RuntimeError::InvalidRequest { .. })),
            "expected InvalidRequest, got {outcome:?}",
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn invalid_deployment_url_is_reported_as_an_error() {
    let client = RuntimeClient::new("ftp://example.com".to_owned(), None);
    let outcome = timeout(
        PROMPTLY,
        client.query(
            "messages:list".to_owned(),
            HashMap::new(),
            Arc::new(CancellationSignal::new()),
        ),
    )
    .await
    .expect("an invalid URL fails without network access");
    match outcome {
        Err(RuntimeError::Internal { message }) => {
            assert!(
                message.contains("Could not create the Convex client"),
                "{message}"
            )
        }
        other => panic!("expected Internal, got {other:?}"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_signal_cancelled_before_the_call_returns_immediately() {
    let (_listener, url) = unresponsive_deployment();
    let client = RuntimeClient::new(url, None);
    let cancellation = Arc::new(CancellationSignal::new());
    cancellation.cancel();
    cancellation.cancel();

    let query = client
        .query(
            "messages:list".to_owned(),
            HashMap::new(),
            Arc::clone(&cancellation),
        )
        .await;
    assert!(matches!(query, Err(RuntimeError::Cancelled)), "{query:?}");
    let subscription = client
        .subscribe(
            "messages:list".to_owned(),
            HashMap::new(),
            Arc::new(IgnoredResults),
            cancellation,
        )
        .await;
    assert!(
        matches!(subscription, Err(RuntimeError::Cancelled)),
        "{subscription:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancellation_interrupts_every_pending_operation() {
    let (_listener, url) = unresponsive_deployment();
    let client = Arc::new(RuntimeClient::new(url, None));

    for operation in ["query", "mutation", "action", "subscribe"] {
        let cancellation = Arc::new(CancellationSignal::new());
        let pending = {
            let client = Arc::clone(&client);
            let cancellation = Arc::clone(&cancellation);
            tokio::spawn(async move {
                let path = "messages:list".to_owned();
                let args = arguments(&[("limit", "10")]);
                match operation {
                    "query" => client.query(path, args, cancellation).await.map(drop),
                    "mutation" => client.mutation(path, args, cancellation).await.map(drop),
                    "action" => client.action(path, args, cancellation).await.map(drop),
                    _ => client
                        .subscribe(path, args, Arc::new(IgnoredResults), cancellation)
                        .await
                        .map(drop),
                }
            })
        };
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(
            !pending.is_finished(),
            "{operation} completed against a silent deployment"
        );

        cancellation.cancel();
        let outcome = timeout(PROMPTLY, pending)
            .await
            .unwrap_or_else(|_| panic!("{operation} ignored cancellation"))
            .expect("operation task");
        assert!(
            matches!(outcome, Err(RuntimeError::Cancelled)),
            "{operation}: {outcome:?}"
        );
    }
}

struct ConnectionRecorder(mpsc::UnboundedSender<ConnectionState>);

impl ConnectionObserver for ConnectionRecorder {
    fn on_state_change(&self, state: ConnectionState) -> Result<(), RuntimeError> {
        let _ = self.0.send(state);
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connection_state_is_reported_after_the_first_operation() {
    let (_listener, url) = unresponsive_deployment();
    let (sender, mut states) = mpsc::unbounded_channel();
    let client = RuntimeClient::new(url, Some(Arc::new(ConnectionRecorder(sender))));

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        states.try_recv().is_err(),
        "constructing the client must not connect"
    );

    let cancellation = Arc::new(CancellationSignal::new());
    let pending = client.query(
        "messages:list".to_owned(),
        HashMap::new(),
        Arc::clone(&cancellation),
    );
    tokio::pin!(pending);
    let state = tokio::select! {
        state = states.recv() => state,
        outcome = &mut pending => panic!("query completed early: {outcome:?}"),
        _ = tokio::time::sleep(PROMPTLY) => None,
    };
    assert_eq!(state, Some(ConnectionState::Connecting));
    cancellation.cancel();
    assert!(matches!(pending.await, Err(RuntimeError::Cancelled)));
}

/// A provider that records each fetch and never completes it.
struct StalledProvider {
    requests: mpsc::UnboundedSender<(bool, Arc<TokenRequest>)>,
}

impl AuthTokenProvider for StalledProvider {
    fn fetch_token(
        &self,
        force_refresh: bool,
        request: Arc<TokenRequest>,
    ) -> Result<(), RuntimeError> {
        let _ = self.requests.send((force_refresh, request));
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clearing_the_provider_retires_its_pending_fetch() {
    let (_listener, url) = unresponsive_deployment();
    let client = RuntimeClient::new(url, None);
    let (requests, mut fetches) = mpsc::unbounded_channel();

    timeout(
        PROMPTLY,
        client.set_auth_provider(Some(Arc::new(StalledProvider { requests }))),
    )
    .await
    .expect("installing a provider only queues it")
    .expect("provider installed");
    let (force_refresh, request) = timeout(PROMPTLY, fetches.recv())
        .await
        .expect("the Convex worker fetches a token on installation")
        .expect("a fetch request");
    assert!(!force_refresh);
    let mut finished = Box::pin(request.finished());
    assert!(
        timeout(Duration::from_millis(100), &mut finished)
            .await
            .is_err(),
        "a pending request is not finished",
    );

    timeout(PROMPTLY, client.set_auth_provider(None))
        .await
        .expect("clearing the provider does not wait for the stalled fetch")
        .expect("provider cleared");
    timeout(PROMPTLY, finished)
        .await
        .expect("the retired provider's pending request finishes");
    // A late completion from the retired provider is ignored rather than applied.
    request.complete(Some("retired-token".to_owned()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_the_client_inside_an_async_context_does_not_block_or_panic() {
    let (_listener, url) = unresponsive_deployment();
    let client = RuntimeClient::new(url, None);
    let cancellation = Arc::new(CancellationSignal::new());
    let pending = tokio::spawn({
        let cancellation = Arc::clone(&cancellation);
        async move {
            let outcome = timeout(
                Duration::from_millis(200),
                client.query("messages:list".to_owned(), HashMap::new(), cancellation),
            )
            .await;
            assert!(outcome.is_err(), "the silent deployment cannot answer");
            drop(client);
        }
    });
    timeout(PROMPTLY, pending)
        .await
        .expect("dropping the client returns promptly")
        .expect("drop task");
}
