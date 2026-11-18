---
default: major
---

# Add generated Swift contracts and live Observable queries for Convex

Generate typed Swift requests, document IDs, and results from a separately exported backend contract. The Convex module provides live Observation models, async query events, one-shot queries, mutations, actions, and authentication over the shared Rust runtime. SwiftPM plugins generate source locally without TypeScript or Rust build tooling in application builds. Initial runtime support is arm64 iOS 17 and macOS 14; unsupported contract shapes fail generation instead of silently widening types.
