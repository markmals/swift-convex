# Changelog

No releases have been published.
## 0.1.0 (2026-11-18)

### Breaking Changes

#### Add generated Swift contracts and live Observable queries for Convex

Generate typed Swift requests, document IDs, and results from a separately exported backend contract. The Convex module provides live Observation models with `observe(_:)`, async query snapshots with `snapshots(for:)`, one-shot queries with `fetch(_:)`, and typed operations with `execute(mutation:)` and `execute(action:)`. Authentication and all operations use the shared Rust runtime. SwiftPM plugins generate source locally without TypeScript or Rust build tooling in application builds. Initial runtime support is arm64 iOS 17 and macOS 14; unsupported contract shapes fail generation instead of silently widening types.
