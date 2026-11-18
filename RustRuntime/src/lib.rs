//! Native boundary between swift-convex and the official [`convex`] Rust client.
//!
//! This crate is derived from the `rust/` bridge in
//! [convex-mobile](https://github.com/get-convex/convex-mobile) at
//! `f1a074ac2a4581f6f10f274eb237de05bbc91092` (Apache-2.0); `NOTICE` lists the changes. It
//! exports a UniFFI interface consumed only by the internal `ConvexNative` Swift target. The
//! Convex sync protocol, reconnection, and authentication refresh remain the `convex` crate's.
//!
//! Every value crossing the boundary is a Convex-encoded JSON string. Malformed function paths,
//! JSON, or Convex values are rejected with [`RuntimeError::InvalidRequest`] before the network
//! is used, never by a panic.

mod auth;
mod cancellation;
mod client;
mod error;
mod observers;
mod values;

pub use auth::{AuthTokenProvider, TokenRequest};
pub use cancellation::CancellationSignal;
pub use client::{RuntimeClient, SubscriptionHandle};
pub use error::RuntimeError;
pub use observers::{ConnectionObserver, ConnectionState, QueryObserver};

uniffi::setup_scaffolding!();
