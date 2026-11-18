---
id: guide.verification
title: Verifying Swift Convex
---

# Verifying Swift Convex

`mise run check` runs Swift and Rust unit tests, the tagged external consumer, arm64 iOS device/simulator builds, DocC, lint, and Workbench validation. It uses the selected Xcode toolchain and the pinned Rust toolchain. Native maintainers first run `mise run native:build`; dependent applications use the published binary instead.

## Tagged consumer and private artifacts

`mise run test:consumer` copies the current source snapshot into an isolated repository, tags the version in `Consumer/Package.swift`, and resolves it as a normal SwiftPM dependency. It compiles generated requests and the SwiftUI Observation example without `@testable`, then proves that wrong-table IDs, wrong operation kinds, omitted required arguments, and caller-selected output types are rejected by the compiler.

The consumer deliberately ignores `CONVEX_NATIVE_LOCAL` and downloads the published native artifact. While the repository is private, supply an API-host credential through SwiftPM's normal stores or set `CONVEX_TEST_NETRC` to an external mode-0600 netrc file. GitHub source-repository credentials and binary-download credentials may use different hosts. No token belongs in this repository.

## Live fixture

The separate [exporter repository](https://github.com/markmals/convex-contract-exporter) owns the disposable backend. `Fixtures/LiveBackend/contract.json` was exported from its commit `a33e3e0d5051f33d4cba206a4c83ad7f229cafa8`; the fixture backend binary is pinned there. Preserve that artifact's canonical formatting rather than reformatting it in Swift tooling.

With that repository checked out beside this one:

```sh
(cd ../convex-contract-exporter && npm ci && npm run fixture:backend:up)
CONVEX_INTEGRATION_URL=http://127.0.0.1:3290 mise run test:integration
```

Tests create uniquely named channels on loopback. They exercise generated mutations, actions, one-shot reads, live Observation and async-sequence updates, nullable results, commit timestamps, bytes, Int64 limits, nonfinite doubles, tuples, literals, unions, and omission versus explicit null. Without `CONVEX_INTEGRATION_URL`, they are disabled and never contact a deployment.

To include real token-provider installation and logout, generate a disposable fixture JWT without printing it:

```sh
token_file=$(mktemp)
chmod 600 "$token_file"
trap 'rm -f "$token_file"' EXIT
(cd ../convex-contract-exporter && node scripts/local-backend.mjs token) > "$token_file"
CONVEX_INTEGRATION_URL=http://127.0.0.1:3290 \
CONVEX_INTEGRATION_TOKEN_FILE="$token_file" \
mise run test:integration
```

The authentication proof expects the fixture CLI's default identity, `fixture-user`, and verifies that the Observable identity changes from null to signed-in and back to null. The token is local test material, not a deployment admin key. Stop the fixture with `npm run fixture:backend:down` in the exporter repository; its documented `reset` command deletes the disposable database and generated secrets when review is complete.

## Generation workflows

The external consumer exercises the build plugin. The explicit command plugin uses a target-local configuration with `output` and requires SwiftPM's write permission even in `--check` mode:

```sh
swift package --allow-writing-to-package-directory generate-convex --target MyTarget
swift package --allow-writing-to-package-directory generate-convex --target MyTarget --check
```

The direct `convex-swift-codegen` executable can also generate/check local files without plugin permissions. `--check` compares output without changing it. Unsupported types and naming collisions must fail before the existing output is replaced. The [configuration reference](contract-format.md#swift-configuration) defines naming overrides.

## Native artifacts

`RustRuntime/rust-toolchain.toml` and `Cargo.lock` pin the native toolchain and dependencies. The build uses rustls with ring and bundled roots, then generates Swift bindings with the pinned UniFFI version. Generated bindings are committed but excluded from hand formatting.

```sh
mise run native:build
mise run native:package
```

Outputs under `.build/native/` include `ConvexRuntimeFFI.xcframework.zip`, its SHA-256 file, and provenance. The archive contains arm64 macOS, iOS device, and iOS simulator slices plus license text for linked dependencies. Packaging rejects a changed Cargo lockfile, mismatched bindings/headers, or unrecorded slice hashes.

Before publishing, commit native source and bindings, rebuild, and require `source.nativeSourcesModified` to be false in provenance. Publish an immutable native artifact, then update the URL and checksum in `Package.swift`. Private GitHub release assets use the API asset URL with a `.zip` suffix and SwiftPM authentication. Verify resolution as a consumer before merging the new pin. A successful local native build alone does not verify distribution.

`CONVEX_NATIVE_LOCAL=1` is an explicit maintainer opt-in to `.build/native/ConvexRuntimeFFI.xcframework`. It is not an automatic fallback. `swift package reset` removes that local build; run the build script again afterward. App builds never invoke Cargo or the TypeScript exporter.
