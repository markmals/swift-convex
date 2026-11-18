# Swift Convex

This Swift package follows the Workbench process, loaded from `.workbench`, a gitignored link restored by `mise install`.

## Boundaries

- The public Swift module is `Convex`, with `ConvexClient`, generated request values, and a live Observation-backed `Query` model.
- `Sources/Convex/Coding` owns wire-value semantics; `Requests` owns request and table-ID contracts; `Client` and `Observation` own connection and live-query lifetimes.
- `Sources/ConvexContract`, `ConvexCodegen`, and `ConvexCodegenCLI` plus `Plugins` handle offline Swift generation. No TypeScript source or runtime belongs in this repository.
- The separate `convex-contract-exporter` project owns TypeScript semantic extraction and the integration backend. The shared boundary is `guides/contract-format.md`.
- `RustRuntime` and private native binding targets reuse the official Convex Rust client. Do not reimplement its sync protocol or add the official Swift SDK.

## Verification

Use Xcode's Swift toolchain, Swift 6 language mode, and strict concurrency. Approved runtime platforms are arm64 iOS 17 (device and simulator) and arm64 macOS 14. Generator portability does not imply runtime portability.

`mise run check` runs Swift tests, the tagged external consumer, platform builds, DocC, formatting, and record validation. Native artifacts are built separately by `mise run native:build`. Run the relevant checks before committing; never publish a checksum that does not match the verified artifact.

Generated UniFFI output must retain its matching source/tool versions. Do not hand-edit generated bindings to silence diagnostics. Fix the generator configuration or the narrow native ownership boundary. Project-authored Swift must not use unchecked Sendable or unsafe isolation merely to suppress compiler errors.

Every public declaration has a concise contract doc comment. Generated consumer types receive the same documentation quality. Optionality and nullability must remain distinct; Int64, Float64, bytes, and typed IDs must survive every nested collection.

## Releases

Keep `Package.swift` at the repository root and use Knope's single-package `v<version>` release tags. Native XCFramework artifacts have independent provenance/checksums and are built by maintainers, never by a dependent's Swift build. Keep credentials out of source, fixtures, generated contracts, and logs.
