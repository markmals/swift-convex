---
id: proposal.0001
title: Type-Safe Swift Contracts for Convex
authors: [OpenAI coding assistant]
status: draft
pull-request: https://github.com/markmals/swift-convex/pull/1
issues: []
supersedes: []
---

# Type-Safe Swift Contracts for Convex

## Summary

Generate typed Swift requests, results, and document IDs from a backend-exported, runtime-neutral contract. Expose `ConvexClient` in the `Convex` module, backed by the same Rust client used by the official mobile SDK. SwiftPM plugins generate Swift locally; TypeScript export stays in backend tooling. No macros are required.

## Motivation

Swift developers currently provide Convex function paths as strings, argument dictionaries keyed by strings, and independently chosen decoding types. The compiler cannot connect those three choices. A renamed function, a wrong table's ID, or an inaccurate result model can compile and fail only when the application calls the backend.

The TypeScript client derives those relationships from the backend's generated `api` and `dataModel` declarations. Swift applications need that same source of truth, with Swift names, value types, and concurrency. Handwritten wrappers improve call sites but leave developers maintaining a second schema.

## Domain grounding

### Established context

- Convex's [generated `api`](https://docs.convex.dev/generated-api/api) describes public functions with argument and return types; `internal` describes functions unavailable to ordinary clients. Function kind also determines which client operations accept a reference.
- The [generated data model](https://docs.convex.dev/generated-api/data-model) supplies `Doc<TableName>` and branded `Id<TableName>` types. An ID's brand is a compile-time distinction, not proof of existence or authorization.
- [Deployment-based TypeScript API export](https://docs.convex.dev/production/multiple-repos) uses validators and defaults missing validators to `v.any()`. [`convex function-spec`](https://docs.convex.dev/cli/reference/function-spec) reads deployment metadata. Neither can recover arbitrary return types inferred by the TypeScript compiler from source.
- [Convex values](https://docs.convex.dev/database/types) distinguish Float64 from Int64, support bytes and nonfinite floating-point values, and distinguish missing object properties from null. Top-level `undefined` returns become null; `undefined` array elements are invalid.
- The [official Swift client](https://docs.convex.dev/client/swift) exposes subscriptions, mutations, actions, and authentication over Convex's Rust sync engine. Its [type-conversion guidance](https://docs.convex.dev/client/swift/data-types) requires special handling for numbers. Ordinary synthesized `Codable` is insufficient as a general Convex wire codec.

### Relevant constraints and principles

[Swift's API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) prioritize clarity at the call site, established terminology, argument labels, and consistent naming. Generated nominal request values bind function identity and arguments together. Generic client methods infer their outputs without dynamic member lookup, raw string paths, or a separately supplied argument object.

[Build tool plugins](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) declare generation commands with known inputs and outputs. [Command plugins](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md) support explicit user actions and write permissions. These roles fit local code generation; deployment access does not belong in an application build.

[Expression macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0382-expression-macros.md) and [attached macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md) transform Swift syntax. They do not supply a TypeScript semantic model. A macro on a handwritten Swift function can check its Swift shape without establishing that it matches a backend function.

### Quality bar

For supported contracts, the endpoint fixes the operation kind, arguments, and output at compile time. Wire distinctions survive encoding and decoding. Unsupported types produce a source-located generation error rather than an invented Swift type. A clean application build needs neither Node nor deployment credentials after dependencies and the contract snapshot are available.

### Remaining uncertainty

This is source-based design research, not a tested implementation. The first implementation work must prove extraction of inferred types, complete Convex-value interoperability across the Rust FFI boundary, Swift 6 isolation, authentication, and subscription teardown. Failure of those proofs requires revising the proposal before promising compatibility.

[convex-swift PR #32](https://github.com/convex/convex-swift/pull/32) reports a cancellation crash, an early-cancellation leak, and dropped initial values in the Swift SDK's Combine subscription chain. This proposal now bypasses that layer and consumes the Rust bridge directly, so that PR is evidence for regression scenarios rather than a release dependency. Our Swift callback bridge still needs its own verified lifetime state machine; reusing Rust does not automatically make the language boundary safe.

## Existing baseline

The repository was empty. Its documentation foundation now follows the requested `swift-package` template and that template's Workbench proposal format. [README.md](../README.md) records the template revision and the intentionally partial, proposal-only initialization. There is no existing library contract to migrate.

Preserve the template's root SwiftPM manifest, Swift 6 strict concurrency, Swift Testing, external `Consumer/` verification, DocC, formatting, and version-tag release model when implementation starts. Replace its `SemanticVersion` example completely. Its broad platform claims and Swift-only tooling assumptions need adaptation to the actual transport and exporter.

Preserve Convex's connection, authentication, and synchronization behavior by reusing its Rust client. The TypeScript generated API is the semantic baseline. The existing Swift SDK demonstrates mobile integration, but its string-based API, Combine wrappers, and caller-selected response types are not dependencies of the revised design.

The inspected Swift SDK baseline is `convex-swift` 0.8.2 at `1c69cdd9723ffb5857f48aa360d079ed09d614fd`. Its [manifest](https://github.com/convex/convex-swift/blob/1c69cdd9723ffb5857f48aa360d079ed09d614fd/Package.swift) exposes `ConvexMobile`, with a bundled Rust XCFramework. Its [binary manifest](https://github.com/convex/convex-swift/blob/1c69cdd9723ffb5857f48aa360d079ed09d614fd/libconvexmobile-rs.xcframework/Info.plist) contains arm64 iOS device, arm64 iOS simulator, and arm64 macOS slices. Those are the approved initial platforms; our package owns its binary distribution rather than importing that SDK.

The shared runtime is the [`convex` Rust crate](https://docs.rs/convex/latest/convex/). The official [`convex-mobile` bridge](https://github.com/convex/convex-mobile/blob/f1a074ac2a4581f6f10f274eb237de05bbc91092/rust/src/convex-mobile.udl) already exports query, subscription, mutation, action, authentication, and cancellation through UniFFI. Its inspected [lockfile](https://github.com/convex/convex-mobile/blob/f1a074ac2a4581f6f10f274eb237de05bbc91092/rust/Cargo.lock#L414-L435) pins `convex` 0.10.3; the Rust client's [0.10.4 changelog](https://github.com/convex/convex-rs/blob/1dbad3046e449224f8ec0bdd6b432ff6544ac2f9/CHANGELOG.md#L7-L12) includes a subscription leak fix. These are research snapshots, not an approved release dependency set.

## Proposed solution

Use two generation stages and reuse the existing Rust runtime beneath our Swift client:

```text
Backend repository: source + generated api/dataModel + tsconfig + locked dependencies
    -> separately installed TypeScript contract exporter
    -> versioned, runtime-neutral convex-contract.json
Swift repository: local contract + Swift naming configuration
    -> Swift generator (executable, SwiftPM build/command plugins)
    -> generated request and result types
    -> Convex.ConvexClient
    -> private UniFFI bindings / convex-mobile bridge
    -> official convex Rust client
```

The exporter belongs to the TypeScript/backend toolchain. Swift tooling consumes its published format and contains no TypeScript source, compiler, or interpreter. The intermediate contract records backend semantics without Swift names or runtime-specific types; Swift naming and platform choices remain generator configuration.

Proposed usage:

```swift
import Convex

let convex = ConvexClient(deploymentURL: deploymentURL)
let list = API.Messages.List(channelID: channel.id)

let messages = try await convex.query(list)

let messageID = try await convex.mutate(
    API.Messages.Send(channelID: channel.id, body: "Hello")
)

try await convex.callAction(
    API.Notifications.Deliver(messageID: messageID)
)

let updates = convex.events(for: list)
defer { updates.cancel() }

for try await messages in updates {
    render(messages)
}
```

These are proposed interfaces, not runnable examples today. `API.Messages.List` is a request type whose initializer captures its arguments; constructing it performs no I/O. Its static contract fixes the backend address, query kind, and result type. `API.Messages.Send` fixes the type of `messageID`. Passing a `Send` request to `query` or `events(for:)`, or another table's ID to `channelID`, is a compile error.

## Detailed design

### 1. Extract the TypeScript contract, without executing backend modules

The separate backend-side exporter uses the TypeScript compiler's semantic API to load the project's configuration and resolve its generated public `api` and `dataModel` declarations. It instantiates [`FunctionArgs` and `FunctionReturnType`](https://github.com/convex/convex-backend/blob/4b25436c8558ecd2c6094d8dc3a259572fd65cb0/npm-packages/convex/src/server/api.ts#L616-L697) for each concrete function reference instead of relying on deprecated phantom fields. It does not parse printed type strings with regular expressions or discover functions by executing their modules. This source snapshot is research evidence, not a tested npm compatibility pin.

Required extraction behavior:

- Traverse public API references, preserving module path, export name, query/mutation/action kind, argument object, and client-visible return type. Apply Convex's return normalization, including promises and top-level `void`/`undefined` becoming null. Match the official namespace-to-address rules, including nested modules and default exports, with fixtures.
- Support inferred results without requiring developers to add `returns` validators. Use the resolved public return type even when it is narrower than the validator. Validators remain recommended for runtime validation; requiring them would provide a different contract from normal TypeScript inference.
- Resolve schema document shapes and table-specific IDs through `dataModel`, including `_id`, `_creationTime`, and `_storage` IDs. A schema-less or explicitly dynamic model must be reported as dynamic, never represented as an invented document structure.
- Use only client-callable public references. Omit internal functions, HTTP actions, and component references, which the inspected generator exposes as [internal](https://github.com/convex/convex-backend/blob/4b25436c8558ecd2c6094d8dc3a259572fd65cb0/npm-packages/convex/src/cli/codegen_templates/component_api.ts#L545-L556). Public application wrappers around component functions are ordinary root functions and remain supported.
- Stop on TypeScript errors, unresolved references, an unsupported compiler/Convex version, or a contract node that cannot be represented. Resolve imports with the backend's actual module-resolution settings and locked dependency graph.

The [TypeScript compiler API documentation](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API) currently describes TypeScript 6 and earlier and warns that TypeScript 7.1 has a different API. The exporter must declare a tested compiler compatibility range and fail outside it. Supporting a backend compiler version requires an extraction adapter and fixtures for that version, not a claim that the latest compiler automatically works.

The initial extraction proof must include standard generated declarations and supported self-contained API forms. Convex's [static function-reference generator](https://github.com/convex/convex-backend/blob/4b25436c8558ecd2c6094d8dc3a259572fd65cb0/npm-packages/convex/src/cli/codegen_templates/component_api.ts#L618-L665) derives results from validators and defaults missing ones to `any`. A semantic checker cannot recover inference already erased from that input. Diagnose this case and direct the developer to source-linked generation or explicit validators; do not claim inferred parity for static `any` declarations.

Generating or refreshing Convex's own files remains a separate backend operation. This tool does not silently run `convex dev`, deploy code, or install packages.

### 2. Make the intermediate contract explicit

`convex-contract.json` contains a format version, exporter and dependency versions, a reproducible source fingerprint, public function descriptors, table identities, and a graph of named/referenced value shapes. Shapes retain property presence, nullability, literals, unions, and Convex scalar kinds separately. Record whether types came from source-linked inference, validator-derived static declarations, or an explicitly dynamic position. Function source locations use repository-relative paths. The format contains no Swift identifiers, Swift declarations, or FFI configuration; other language generators can consume the same backend contract.

Canonical ordering and content hashes make output stable across machines. Omit timestamps, absolute paths, credentials, deployment tokens, and machine-specific package paths. The fingerprint covers relevant source/declaration inputs, compiler options, exporter configuration, and dependency locks. Schema metadata itself may be sensitive; teams review what they publish.

Unknown format versions fail before generation. An unsuccessful export or generation leaves the last complete artifact untouched and exits unsuccessfully; consumers must not mistake an old artifact for a successful refresh. Writes are atomic. A `--check` mode compares the newly derived content with the checked-in artifact and reports drift without modifying files.

The default exports the complete public contract. An explicit endpoint selection may support incremental adoption, but the export report must list excluded endpoints. Within the selected contract, unsupported nodes are errors, never silently dropped.

### 3. Generate nominal Swift types

| Convex/TypeScript contract      | Proposed Swift representation                                   | Required semantics                                                                                               |
| ------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `string`, `boolean`             | `String`, `Bool`                                                | No coercion.                                                                                                     |
| `number` / Float64              | `Double`                                                        | Preserve finite values, signed zero, and supported nonfinite values. Never infer `Int` from an integral example. |
| `bigint` / Int64                | `Int64`                                                         | Enforce signed 64-bit range; use Convex's integer wire representation.                                           |
| Resolved commit timestamp       | `Int64`                                                         | Nanoseconds; explicitly normalize the known backend placeholder type at the client boundary.                     |
| `ArrayBuffer` / bytes           | `Data`                                                          | Convex bytes representation, not an array of numeric values.                                                     |
| `Id<"messages">`                | `DocumentID<API.Tables.Messages>`                               | Encode as the original string. Different tables and generated backend namespaces remain distinct types.          |
| `Doc<"messages">`               | Generated document value type                                   | Include `id` and `creationTime` mapped to `_id` and `_creationTime`; preserve schema fields.                     |
| Object                          | Generated `struct`                                              | Public initializer, exact wire keys, required-field checks, `Sendable`.                                          |
| Array                           | `[Element]`                                                     | Preserve order and element types.                                                                                |
| String-keyed record             | `[String: Value]` or a generated constrained-key representation | Preserve Convex object encoding; Swift's non-string-key dictionary array encoding is forbidden.                  |
| Required nullable `T \| null`   | `T?`                                                            | Encode nil as explicit null. Reject a missing required key.                                                      |
| Optional nonnullable property   | `T?`                                                            | Encode nil by omitting the key. Reject explicit null when decoding.                                              |
| Optional nullable property      | `ConvexField<T?>`                                               | `.omitted`, `.value(nil)`, and `.value(value)` remain distinct.                                                  |
| Literal or finite literal union | Generated value type or enum                                    | Enforce literal membership in both directions.                                                                   |
| Discriminated object union      | Generated associated-value enum                                 | Decode by its literal discriminant; reject unknown tags.                                                         |
| Other disjoint union            | Generated associated-value enum                                 | Prove disjointness from wire kinds or required literal fields; never guess by declaration order.                 |
| Null-only result                | `ConvexNull`                                                    | Accept only null, including a backend void result normalized by Convex.                                          |
| Explicitly allowed dynamic node | `ConvexValue`                                                   | A closed enum of Convex wire values, not Swift `Any`.                                                            |

Generated coding implementations handle presence explicitly. Synthesized `decodeIfPresent` conflates missing and null, so it cannot implement all rows above. A package-owned `ConvexValueCodable` protocol supplies typed encoding and decoding for scalars, collections, and generated models. The runtime decoder calls that codec recursively on the native bridge's response payload. This matters for outputs such as `[Double]`, whose standard `Decodable` conformance cannot decode Convex float envelopes. Integer, float, and bytes handling cannot depend on a property wrapper appearing at one particular nesting level.

`creationTime` stays a `Double` measured in milliseconds; any `Date` convenience is an explicit conversion. IDs do not conform to `ExpressibleByStringLiteral`. Interoperability with stored raw IDs uses a visibly unchecked initializer; no offline initializer claims to verify the table or document's existence.

[Commit timestamp placeholders](https://docs.convex.dev/database/advanced/commit-timestamp) resolve at mutation commit time, including in return values; their client-visible value is an Int64 in nanoseconds. Recognize Convex's actual placeholder symbol, rather than any similarly named class, and record this client-boundary normalization in the intermediate contract. Swift callers may send resolved integers, never a placeholder. Receiving an unresolved `$commitTs` is a decoding error. This exception does not permit arbitrary class-to-scalar coercions.

Reject overlapping unions that cannot be normalized to disjoint cases, and recommend a backend discriminant. Never select the first case whose decoder happens to succeed. Fixed tuples become generated fixed-field value types with exact-length array coding. Normalize concrete intersections to their resolved wire shape; reject incompatible or unresolved intersections. Constrained record keys use generated key types and explicit object-key coding. Recursive or otherwise unrepresentable shapes produce a diagnostic rather than an array/dictionary approximation.

`any`, `unknown`, and `v.any()` fail in strict generation by default. An explicit, path-scoped configuration can opt a known dynamic position into `ConvexValue`; the artifact and generated API identify that loss of static specificity. Unresolved conditional types, unconstrained generics, functions, symbols, and non-wire classes fail. A new Convex value kind also fails until its wire behavior is supported and tested.

Swift nominal typing cannot preserve every TypeScript structural assignment. Endpoint-local shapes get stable names derived from module/function/position; schema documents share their generated document type where their identity is established. Do not deduplicate unrelated shapes merely because their current fields happen to match.

### 4. Bind function identity, arguments, and output in request values

Generate one immutable, `Sendable` request struct per function. `API.Messages.List` stores `channelID` directly and conforms to `QueryRequest`; `API.Messages.Send` conforms to `MutationRequest`; `API.Notifications.Deliver` conforms to `ActionRequest`. The three protocols share the request encoding contract, and each request fixes its `Output` associated type and static backend address. There is no independent reference and arguments pair at the call site.

| Operation        | Accepted request  | Result                                                                       |
| ---------------- | ----------------- | ---------------------------------------------------------------------------- |
| `query(_:)`      | `QueryRequest`    | One decoded `Request.Output`, asynchronously.                                |
| `events(for:)`   | `QueryRequest`    | `QueryEvents<Request.Output>`, a throwing async sequence of query snapshots. |
| `mutate(_:)`     | `MutationRequest` | One decoded `Request.Output`, asynchronously.                                |
| `callAction(_:)` | `ActionRequest`   | One decoded `Request.Output`, asynchronously.                                |

Each method is generic over the concrete request, rather than an unconstrained output type. The same query value can be reused for one-shot execution and observation. Constructing or copying it does not start a request or allocate a second arguments wrapper. No-argument functions use their request's empty initializer, such as `API.Health.Check()`. Initializers require every required field and give only genuinely optional fields an omission default. A required nullable field still requires an explicit argument.

The protocols are public so generated requests in a consumer module can conform. Handwritten conformances are an explicit trust boundary and do not prove agreement with the backend. Ordinary client methods accept only request values; they have no raw-string overload or result-type parameter.

Use UpperCamelCase for generated namespace and request types, such as `API.Messages.List`, and lowerCamelCase for stored arguments and client methods. Preserve module nesting and backend export vocabulary. Normalize acronym spellings deliberately, such as `channelID`, and retain an exact wire-name map. Escape Swift keywords and string literals. Detect normalization collisions, including case-insensitive file-name collisions, and require an explicit name override; do not add unstable numeric suffixes.

The root namespace is configurable so an application can import contracts for more than one backend. Naming overrides change Swift spelling only, never routing or wire keys. Generated declarations carry documentation describing units, presence semantics, and the backend source location.

### 5. Reuse the Rust runtime and own the Swift boundary

`ConvexClient` is our public client in the `Convex` module. It creates and owns one native client from a deployment URL. It neither wraps nor depends on `ConvexMobile`, and adopting applications replace the official Swift client rather than linking both front ends. Reuse the official `convex` crate for WebSocket transport, query tracking, synchronization, reconnect behavior, mutation semantics, and authentication refresh.

Use the existing `convex-mobile` Rust/UniFFI bridge as the starting boundary, with generated Swift bindings hidden behind an internal target. Pin its source revision, Rust dependency lockfile, UniFFI version, and generated bindings together. Do not expose UniFFI objects or callback protocols in the public Swift API. This is an FFI and packaging responsibility, not a new implementation of the Convex protocol.

The [native interface](https://github.com/convex/convex-mobile/blob/f1a074ac2a4581f6f10f274eb237de05bbc91092/rust/src/convex-mobile.udl) already exposes a one-shot `query`. Call that from `query(_:)` rather than reproducing subscribe-then-first in Swift. `mutate(_:)` and `callAction(_:)` call the corresponding native operations and decode the request's fixed output. Null is a successful value. Use the same native client for all operations and do not introduce a separate HTTP transport.

The bridge takes an argument-name map whose values are Convex-encoded JSON strings and returns Convex-encoded JSON payloads. Encode request fields directly: an absent key is omission; a present null-encoding value is null. Escape nested keys and preserve scalar envelopes at every nesting level. Decode responses once through our codec, preserving decoding errors and coding paths directly. No SDK-specific `ConvexEncodable` conformers, numeric wrappers, or decoding-outcome workaround remain. Avoid a generic JSON-tree round-trip for statically typed requests; the strings and FFI transfers required by this bridge are measurable boundary costs.

The inspected bridge [parses arguments with `expect`](https://github.com/convex/convex-mobile/blob/f1a074ac2a4581f6f10f274eb237de05bbc91092/rust/src/lib.rs#L354-L371). Before release, that boundary must return a structured error for invalid JSON or invalid Convex values instead of panicking. Prefer upstream bridge fixes; retain only small, documented binding/ownership patches if needed. Do not fork the sync engine or replace failures with retries.

Make `ConvexClient` safely shareable through compiler-checked `Sendable` storage backed by isolated native ownership. Calls must be usable from the main actor without making the library main-actor-only. Native callbacks arrive on Rust runtime threads; serialized Swift lifetime state owns their delivery, cancellation, and teardown. Audit generated FFI concurrency assumptions and prove them under Swift 6. Do not add unchecked conformances or unsafe isolation annotations merely to suppress diagnostics.

`events(for:)` returns a `QueryEvents<Output>` async sequence with synchronous, idempotent `cancel()`. Creating it performs no network operation; its single iterator starts one subscription. Use a new `events(for:)` call for another independent consumer. Establish buffering and callback ownership before native registration can emit an initial value. Task cancellation, iterator release, explicit cancellation, and terminal error tear down that subscription. If cancellation wins the registration race, cancel the native handle as soon as it arrives. After cancellation takes effect, discard buffered and late native updates instead of forwarding them to the consumer. A retained sequence can outlive an early loop exit, so use `defer` when deterministic teardown is needed.

Despite the method name, query events carry result snapshots, not a durable event log. Use a bounded newest-snapshot buffer and document coalescing for a slow consumer. Preserve callback order before coalescing. Forward reconnection to the Rust client; a terminal error ends this sequence and cancels its handle. Do not silently resubscribe, replace failures with empty collections, or invent automatic action retries.

For one-shot calls, connect Swift task cancellation to the owned native future where the pinned bridge permits it. Completion and cancellation must settle the Swift waiter exactly once; if cancellation wins, it throws `CancellationError` rather than returning a fabricated result. Prove resource release independently of that Swift result. The bridge's cancellation behavior is an implementation gate, not an inherited Swift SDK guarantee. In particular, a mutation or action may execute after the caller cancels, so canceling a wait never implies server rollback.

Authentication also crosses our boundary. Expose a Swift `Sendable` token provider with an async, throwing token lookup that receives `forceRefresh` and returns an optional token. `setAuthenticationProvider(_:)` installs it through the bridge's existing auth callback; passing nil clears it. The application owns login UI and credentials. Preserve refresh on reconnect, serialize provider replacement/logout, and prevent a late result from a retired provider from restoring an old session. Provider state and connection state must be observable without importing the official Swift SDK; retrieving a token does not prove server authorization. Provider-specific login packages are separate integrations.

Use ordinary `async throws`; transport failures and user-thrown `ConvexError` payloads are not a statically enumerated TypeScript throws contract. Preserve native error categories and application payloads, and distinguish local contract-decoding failures with endpoint and coding-path context. Do not log arguments, response bodies, or credentials by default.

### 6. Give plugins and macros separate responsibilities

The Swift executable `convex-swift-codegen` reads only a local contract and local naming configuration. A thin `ConvexGenerate` build tool plugin invokes it using a build command with declared inputs and outputs. Start with one known output file per generated target to keep invalidation and stale-output removal predictable. Write only to the plugin work directory; never modify package sources during a build.

The explicit `generate-convex` command plugin invokes the same generator for teams that commit generated source. It requests source-write permission and supports checking without writing. These are alternative workflows per target: checked-in declarations must not also be generated into that target by the build plugin.

Proposed workflow:

```sh
# In the backend repository, using its lockfile-installed TypeScript exporter.
convex-contract-export --project convex/tsconfig.json --output contracts/convex-contract.json
convex-contract-export --project convex/tsconfig.json --output contracts/convex-contract.json --check

# Swift consumer choosing checked-in generation instead of the build plugin.
swift package --allow-writing-to-package-directory generate-convex
swift package generate-convex --check
```

These command names are proposed. The exporter is a separately distributed backend development dependency with its own source, compiler dependencies, and tests. Swift tooling includes none of that TypeScript implementation. Neither Swift plugin installs or invokes Node, accesses a deployment, or needs a deploy key. Backend automation may explicitly run export before a Swift build, but ordinary Swift generation reads only the local contract snapshot.

Provide SwiftPM package-target integration and Xcode build-tool integration through the appropriate plugin host APIs. Also support generating a standalone Swift contract package consumed by an Xcode application; this avoids requiring every application target to host a generator. Test both hosts, including a clean build, incremental regeneration, and file removal.

No mandatory macros are part of the approved initial scope. The generator already knows every property and can emit complete, inspectable declarations. Expanding a second layer of macros would add a SwiftSyntax dependency and another diagnostic boundary without recovering more backend information. An optional `@ConvexModel` macro could later share coding synthesis for handwritten models, but it would not verify backend equivalence and is outside this proposal's delivery scope.

### 7. Adapt the package template at implementation time

Use `swift-convex` as the package identity and `Convex` as the public product/module, with `ConvexClient` as its client type. Keep the manifest at the repository root. Add internal native bindings and binary targets, plus separate host targets for the Swift generator, build plugin, and command plugin. Keep the generator's dependency graph independent of the native runtime so contract generation does not load or link an application client.

Keep TypeScript implementation in the separately distributed backend exporter, not under this Swift package's `tools/`. Its repository owns extraction fixtures and a representative Convex backend. This repository owns the neutral format specification/fixtures and the Swift consumer of that format. Coordinate compatibility through the format version and an integration matrix, rather than embedding TypeScript tooling or requiring the two packages to share a release number.

Build the Rust bridge and its generated bindings as a matched release artifact. Publish a checksummed XCFramework with arm64 iOS device, arm64 iOS simulator, and arm64 macOS slices, and reference it through SwiftPM's binary-target mechanism. Application builds require neither Cargo nor UniFFI generation; maintainers' native release builds do. Record source revisions, `Cargo.lock`, compiler/SDK versions, deployment floors, build commands, and artifact checksums so a binary can be traced to its source and rebuilt. Verify distribution through the same dependency path consumers use.

Arm64 iOS/macOS support and no mandatory macros are approved in the review. Retain the template's proposed iOS 17 and macOS 14 application floors. Intel Mac/simulator, universal Mac, Catalyst, Linux runtime, watchOS, tvOS, and visionOS are outside the initial verified matrix. Portable generator checks do not establish runtime portability.

After the proposal is settled, adapt the remaining template tooling: Swift 6.4 tools mode, strict concurrency, Swift Testing, public DocC, external consumer tests, mise/hk formatting and gates, and Knope's single-package `v<version>` tags. Add native build/packaging gates for maintainers. Do not ship the template's example library as a placeholder product.

Choose and lock a compatible Rust runtime/bridge combination that includes the subscription leak fix recorded in `convex` 0.10.4, then verify it; do not ship the inspected 0.10.3 lockfile unchanged. The maintenance cost now includes FFI generation, Swift concurrency/lifetime code, binary size/downloads, and native release CI. Review Apache-2.0 notices and the bundled Rust dependencies' redistribution obligations. No project license or public release is established by this draft.

[README.md](../README.md) gains verified installation and generation instructions only when they work. [VISION.md](../VISION.md) gains an implementation claim only after acceptance. The codec, generation format, native artifact provenance, and compatibility matrix need current reference documentation when implementation starts; they presently have no source outside this draft. No architecture decision is marked accepted in this change.

### 8. Prove the contract before release

Implementation proceeds through these dependent proofs, all within the proposal's scope:

1. In the backend exporter, extract a representative project containing an inferred result without a return validator, a schema document, a branded ID, optional/null fields, a union, and all three callable function kinds. Compare the exported contract with TypeScript's public helper types. Establish compiler/Convex versions and give the Swift generator only the resulting neutral artifact.
2. Build the pinned Rust runtime/bridge and generated bindings for every approved slice. Prove Swift 6 ownership and native callback ordering. Round-trip supported scalar/composite values across the FFI boundary, including Int64 boundaries, nonfinite doubles, signed zero, bytes, omitted/null fields, escaped keys, and nested collections. Invalid payloads must fail without a native panic. Verify the binary checksum/provenance and subscription leak fix.
3. Compile an external Swift consumer using `import Convex`, `ConvexClient`, and constructed requests such as `API.Messages.List(channelID:)`. Wrong initializer labels/types, missing required fields, wrong-table IDs, wrong operation kind, and internal-function requests must fail compilation for the intended reason. Regeneration must update or remove changed request declarations. Reusing a query request with `query(_:)` and `events(for:)` must work.
4. Exercise both plugin hosts and the Rust-backed runtime: deterministic generation, unsupported-type diagnostics, drift checks, generation without TypeScript or Cargo installed, clean offline builds after dependency resolution, native one-shot queries, cached initial subscription values, early cancellation, callback/cancel races, reconnect, auth refresh and provider replacement/logout, task cancellation, and teardown against a disposable backend.

Use Swift Testing and the template's tagged-dependency `Consumer/` harness for public API verification. Snapshot tests supplement compiled consumers; they cannot establish type safety alone. Native bridge tests cover malformed inputs and lifetime races. Backend integration checks use a versioned fixture from the exporter project and run in an explicitly configured CI job with isolated test data and secrets, never inside a consumer's build plugin.

## Compatibility

There are no existing users of this package. Adoption replaces the official Swift SDK with `Convex` and `ConvexClient`; the two Swift clients are not intended to coexist in one application. Migrate string calls to generated request values and adapt authentication providers to our token-provider boundary. There is no compatibility wrapper around the old Swift client. Backend function names and stored documents do not change, and the underlying Convex Rust runtime remains shared.

Type safety is relative to the generated snapshot and supported value set. It cannot prove deployment freshness, authorization, ID existence, server business rules, or correctness of a backend type assertion. A deployed incompatible change may still cause a runtime decoding or routing error.

Backend CI checks snapshot freshness. Swift CI checks snapshot-to-source consistency. A consumer without backend source cannot independently prove that a snapshot matches the deployment. A fingerprint records provenance; it is not a server attestation. Support additive server fields during decoding where the declared shape permits them, while rejecting missing required fields, invalid known values, and unknown closed-union tags.

## Implications on adoption

Backend maintainers run a pinned exporter and distribute the resulting contract. Swift developers add the runtime plus either a build plugin or generated sources. They stop maintaining parallel endpoint dictionaries and result structs for adopted functions, and adapt to nominal types where TypeScript previously allowed structural assignment.

The application cost is a generated-artifact workflow and the native runtime dependency. Library maintainers additionally own the Swift FFI boundary and binary release pipeline; backend maintainers install a separate TypeScript exporter. Neither TypeScript nor Rust build tooling is bundled into the Swift generator or required for an ordinary application build. Plugin-based generation removes generated-source churn; checked-in generation makes declarations directly reviewable. Both paths consume the same neutral contract.

## Scope

This proposal defines one coherent feature: a generated, typed Swift client backed by the same Rust runtime as the official mobile client. Delivery includes the separate backend exporter, neutral format, Swift codecs and request/result types, typed operations and query events, authentication/lifetime boundary, native artifact distribution, generator, both plugin workflows, documentation, and the proofs above.

This commit delivers the proposal and template-derived documentation foundation only. Implementation requires the human to settle the proposal and move it to `awaiting-implementation`.

### Out of scope

- A new networking/sync engine or Linux runtime support, because this package reuses the official Rust client's protocol behavior and verifies only the approved initial platforms.
- Swift backend authoring, internal/admin function execution, and HTTP action client generation, because those are different contracts from the public generated Convex API.
- SwiftUI wrappers, optimistic-update caches, and automatic pagination controllers, because they add state-management behavior beyond typed function calls. Pagination-shaped arguments and results remain ordinary supported contracts.
- Mandatory macros or handwritten schema DSLs, because neither is needed to derive this contract and both create another representation to maintain.
- Coexistence or API compatibility with the official Swift SDK, because this package replaces that front end while retaining the shared Rust engine.
- Complete translation of arbitrary TypeScript, because the generator supports concrete Convex wire contracts and explicitly diagnoses the rest.

## Preview

The design preview is this draft and its representative Swift call sites. No implementation is claimed.

The implementation preview is a private prerelease package plus the external `Consumer/` fixture targeting a disposable Convex backend. The reviewer generates a contract, compiles a valid call, observes an invalid call fail, receives a live update, and cancels a subscription. Provide access through the repository's private branch/artifact and environment-supplied deployment configuration. Remove the disposable deployment and credentials after review; keep credential-free fixtures as regression coverage.

## Policies and decisions checked

None exist in this newly initialized repository. The template's [proposal lifecycle](./README.md) reserves implementation approval for the human. The [initial vision](../VISION.md) requires source-derived contracts, faithful wire semantics, and visible limits. This draft proposes departures from the template's platform breadth and Swift-only tooling assumptions explicitly rather than inheriting inaccurate claims.

## Future directions

An optional model-coding macro could help teams writing custom Swift boundary types after the generated codec contract stabilizes. SwiftUI observation, richer pagination, and an independently verified additional transport would each need their own proposal. None is necessary to prove generated type-safe calls on the initial platforms.

## Alternatives considered

| Approach                                             | Benefit                                                                                    | Cost and recommendation                                                                                                                                                                 |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source-semantic export plus local Swift generation   | Preserves TypeScript inference and separates backend tooling from application builds.      | Requires a compiler compatibility matrix and a backend export step. Recommended.                                                                                                        |
| `function-spec` or OpenAPI as the only input         | Simpler discovery; works without backend source; validators are explicit runtime evidence. | Missing validators lose inferred types; an HTTP-oriented client also does not supply live query semantics. Suitable for a validator-complete alternative, not the default parity claim. |
| Handwritten Swift declarations with macros           | Pleasant Swift syntax and less local coding boilerplate.                                   | Duplicates the contract and cannot detect backend drift on its own. Useful only as an explicitly unchecked/custom boundary.                                                             |
| Run TypeScript discovery inside a Swift build plugin | One apparent build step in a monorepo.                                                     | Couples Swift builds to Node, backend source/configuration, and potentially deployment work. Rejected in favor of the reviewed backend-exported neutral contract.                       |
| Wrap `ConvexMobile` and retain its client instance   | Reuses the existing Swift authentication and Combine integration with less binding work.   | Rejected in review. Direct Rust reuse provides our own public API and native query path without the SDK's publisher layer, at the cost of owning Swift FFI and binary releases.         |

## Open questions

None requiring a product decision remain from the submitted [review](https://github.com/markmals/swift-convex/pull/1#pullrequestreview-5948278858). This revision adopts `Convex`, `ConvexClient`, constructed request values, `query(_:)`, `callAction(_:)`, `events(for:)`, a separate TypeScript-side exporter of a neutral contract, and the shared Rust runtime. `mutate(_:)` keeps its existing name. The approved initial scope is arm64 iOS/macOS with no mandatory macros.

The native ownership, codec, artifact distribution, and compiler-version proofs remain engineering gates. Their failure requires an explicit design revision. The proposal stays `draft`; incorporating the review and recording its scoped approvals does not authorize implementation.
