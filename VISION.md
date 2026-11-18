---
title: A Vision for Swift Convex
updated: 2026-11-18
---

# A Vision for Swift Convex

## Introduction

Swift Convex gives Swift applications a compiler-checked contract with their Convex backend. Developers should discover functions, supply arguments, and consume results through Swift declarations derived from the backend, without maintaining a parallel set of string paths and handwritten response types.

[Proposal 0001](proposals/0001-type-safe-swift-contracts.md) implements the initial contract, generator, and Rust-backed client, including live Observation-backed queries. The implementation is accepted for merge. A versioned Swift library release requires separate authorization.

## Goals

- Catch endpoint, argument, result, and document-ID mismatches before an application runs.
- Preserve the meaning of Convex values across the language boundary, including distinctions that ordinary JSON or optional decoding can erase.
- Make generated APIs readable at the call site and inspectable in source, using Swift naming, value types, and concurrency conventions.
- Keep application builds reproducible without deployment credentials or a running backend.

## Minimum viable product

A developer can derive Swift contracts from a real Convex backend, use them for a live query and typed mutation and action calls, and see incompatible backend changes fail generation or compilation. Inferred TypeScript returns and table-specific document IDs remain useful without a duplicate Swift schema. The supported contract subset and every unsupported shape are explicit.

## Design principles

- Fidelity before convenience. Preserve wire meaning and fail on an unsupported contract rather than silently widening it.
- One source of truth. Swift declarations follow the backend contract; application developers do not maintain a second endpoint catalogue.
- Swift at the boundary. Choose names and types for clear Swift use while retaining exact backend names for transport.
- Reuse proven transport. Preserve Convex's authentication and subscription semantics instead of starting a competing networking stack.
- Visible limits. Static types describe a generated snapshot, not authorization, document existence, or an assurance that a deployment matches it.

## Beyond the minimum

- Additional SwiftUI conveniences and pagination controllers may improve application ergonomics beyond the initial live Observable query model.
- Additional transports may extend platform coverage if their authentication, consistency, and subscription behavior can be verified.

## Non-goals

- Authoring Convex backend functions in Swift, because the source contract belongs to the existing backend.
- Reimplementing Convex's database or synchronization protocol, because that creates a separate correctness and maintenance burden.
- Claiming equivalence between Swift's nominal types and all TypeScript types, because some structural and dynamic contracts have no lossless static Swift representation.

## Revision history

| Date       | Change                                                                                    | Related proposal                                             |
| ---------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 2026-11-17 | Recorded the initial project intent; architecture remains a draft.                        | [proposal.0001](proposals/0001-type-safe-swift-contracts.md) |
| 2026-11-18 | Accepted the generated contracts, typed client, and live Observable query implementation. | [proposal.0001](proposals/0001-type-safe-swift-contracts.md) |
