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

Generate Swift function references, arguments, results, and document IDs from Convex's TypeScript contract. Reuse the official Swift transport behind a typed client. Export the contract beside the backend, then generate Swift offline through a SwiftPM build plugin. Keep macros optional rather than making them responsible for backend discovery.

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

[Swift's API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) prioritize clarity at the call site, established terminology, argument labels, and consistent naming. The proposed API uses nominal argument/result types and generics rather than dynamic member lookup or string interpolation.

[Build tool plugins](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) declare generation commands with known inputs and outputs. [Command plugins](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md) support explicit user actions and write permissions. These roles fit local code generation; deployment access does not belong in an application build.

[Expression macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0382-expression-macros.md) and [attached macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md) transform Swift syntax. They do not supply a TypeScript semantic model. A macro on a handwritten Swift function can check its Swift shape without establishing that it matches a backend function.

### Quality bar

For supported contracts, the endpoint fixes the operation kind, arguments, and output at compile time. Wire distinctions survive encoding and decoding. Unsupported types produce a source-located generation error rather than an invented Swift type. A clean application build needs neither Node nor deployment credentials after dependencies and the contract snapshot are available.

### Remaining uncertainty

This is source-based design research, not a tested implementation. The first implementation work must prove extraction of inferred types, full-value codec interoperability through the SDK's public API, Swift 6 isolation, and subscription teardown. Failure of those proofs requires revising the proposal before promising compatibility.

There is also a known upstream prerequisite: [convex-swift PR #32](https://github.com/convex/convex-swift/pull/32), still open when inspected, reports a cancellation crash, an early-cancellation leak, and dropped initial subscription values. The [0.8.2 implementation](https://github.com/convex/convex-swift/blob/1c69cdd9723ffb5857f48aa360d079ed09d614fd/Sources/ConvexMobile/ConvexMobile.swift#L44-L83) still uses the affected publisher chain. A typed wrapper cannot recover an event already lost inside that chain. Reliable subscriptions and one-shot fetch require an upstream fix or a separately approved, narrowly maintained fork; timeouts and retries would hide the defect.

## Existing baseline

The repository was empty. Its documentation foundation now follows the requested `swift-package` template and that template's Workbench proposal format. [README.md](../README.md) records the template revision and the intentionally partial, proposal-only initialization. There is no existing library contract to migrate.

Preserve the template's root SwiftPM manifest, Swift 6 strict concurrency, Swift Testing, external `Consumer/` verification, DocC, formatting, and version-tag release model when implementation starts. Replace its `SemanticVersion` example completely. Its broad platform claims and Swift-only tooling assumptions need adaptation to the actual transport and exporter.

Preserve the official Convex client's connection, authentication, and synchronization behavior. Its string-based dispatch and caller-selected response types are the boundary this package improves. The TypeScript generated API is the semantic baseline; copying a particular JavaScript object layout is incidental.

The inspected SDK baseline is `convex-swift` 0.8.2 at `1c69cdd9723ffb5857f48aa360d079ed09d614fd`. Its [manifest](https://github.com/convex/convex-swift/blob/1c69cdd9723ffb5857f48aa360d079ed09d614fd/Package.swift) exposes `ConvexMobile`, with a bundled Rust XCFramework. Its [binary manifest](https://github.com/convex/convex-swift/blob/1c69cdd9723ffb5857f48aa360d079ed09d614fd/libconvexmobile-rs.xcframework/Info.plist) contains only arm64 iOS device, arm64 iOS simulator, and arm64 macOS slices. Version 0.8.2 is a research baseline, not an approved runtime dependency.

## Proposed solution

Use two generation stages with a small runtime adapter:

```text
Backend source + generated api/dataModel + tsconfig + locked dependencies
    -> TypeScript semantic exporter (explicit backend task)
    -> versioned convex-contract.json (committed or published artifact)
    -> Swift generator (local executable, SwiftPM build/command plugins)
    -> generated Swift declarations
    -> typed client -> official ConvexMobile transport
```

The exporter reads the resolved TypeScript contract, including inferred results. The intermediate representation separates backend tooling from application builds and gives separately maintained backend and Swift repositories a reviewable artifact.

Proposed usage, inside a main-actor-isolated application method with an existing authenticated or unauthenticated SDK client:

```swift
import SwiftConvex

let convex = TypedConvexClient(wrapping: existingClient)

let messages = try await convex.fetch(
    API.messages.list,
    arguments: .init(channelID: channel.id)
)

let messageID = try await convex.mutate(
    API.messages.send,
    arguments: .init(channelID: channel.id, body: "Hello")
)

try await convex.run(
    API.notifications.deliver,
    arguments: .init(messageID: messageID)
)

let updates = convex.subscribe(
    to: API.messages.list,
    arguments: .init(channelID: channel.id)
)
defer { updates.cancel() }

for try await messages in updates {
    render(messages)
}
```

These are proposed interfaces, not runnable examples today. The generated `send` reference determines the type of `messageID`; the caller cannot select an unrelated decoding type. Passing `API.messages.send` to `fetch` is a compile error. Passing an ID for another table to `channelID` is a compile error.

## Detailed design

### 1. Extract the TypeScript contract, without executing backend modules

The backend-side exporter uses the TypeScript compiler's semantic API to load the project's configuration and resolve its generated public `api` and `dataModel` declarations. It instantiates [`FunctionArgs` and `FunctionReturnType`](https://github.com/convex/convex-backend/blob/4b25436c8558ecd2c6094d8dc3a259572fd65cb0/npm-packages/convex/src/server/api.ts#L616-L697) for each concrete function reference instead of relying on deprecated phantom fields. It does not parse printed type strings with regular expressions or discover functions by executing their modules. This source snapshot is research evidence, not a tested npm compatibility pin.

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

`convex-contract.json` contains a format version, exporter and dependency versions, a reproducible source fingerprint, public function descriptors, table identities, and a graph of named/referenced value shapes. Shapes retain property presence, nullability, literals, unions, and Convex scalar kinds separately. Record whether types came from source-linked inference, validator-derived static declarations, or an explicitly dynamic position. Function source locations use repository-relative paths.

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

Generated coding implementations handle presence explicitly. Synthesized `decodeIfPresent` conflates missing and null, so it cannot implement all rows above. A package-owned `ConvexValueCodable` protocol supplies typed encoding and decoding for scalars, collections, and generated models. An SDK-facing `Decodable` envelope calls that codec recursively. This matters for outputs such as `[Double]`, whose standard `Decodable` conformance cannot decode Convex float envelopes. Integer, float, and bytes handling cannot depend on a property wrapper appearing at one particular nesting level.

`creationTime` stays a `Double` measured in milliseconds; any `Date` convenience is an explicit conversion. IDs do not conform to `ExpressibleByStringLiteral`. Interoperability with stored raw IDs uses a visibly unchecked initializer; no offline initializer claims to verify the table or document's existence.

[Commit timestamp placeholders](https://docs.convex.dev/database/advanced/commit-timestamp) resolve at mutation commit time, including in return values; their client-visible value is an Int64 in nanoseconds. Recognize Convex's actual placeholder symbol, rather than any similarly named class, and record this client-boundary normalization in the intermediate contract. Swift callers may send resolved integers, never a placeholder. Receiving an unresolved `$commitTs` is a decoding error. This exception does not permit arbitrary class-to-scalar coercions.

Reject overlapping unions that cannot be normalized to disjoint cases, and recommend a backend discriminant. Never select the first case whose decoder happens to succeed. Fixed tuples become generated fixed-field value types with exact-length array coding. Normalize concrete intersections to their resolved wire shape; reject incompatible or unresolved intersections. Constrained record keys use generated key types and explicit object-key coding. Recursive or otherwise unrepresentable shapes produce a diagnostic rather than an array/dictionary approximation.

`any`, `unknown`, and `v.any()` fail in strict generation by default. An explicit, path-scoped configuration can opt a known dynamic position into `ConvexValue`; the artifact and generated API identify that loss of static specificity. Unresolved conditional types, unconstrained generics, functions, symbols, and non-wire classes fail. A new Convex value kind also fails until its wire behavior is supported and tested.

Swift nominal typing cannot preserve every TypeScript structural assignment. Endpoint-local shapes get stable names derived from module/function/position; schema documents share their generated document type where their identity is established. Do not deduplicate unrelated shapes merely because their current fields happen to match.

### 4. Bind operation, arguments, and output in each reference

The runtime exposes separate `QueryReference<Arguments, Output>`, `MutationReference<Arguments, Output>`, and `ActionReference<Arguments, Output>` value types. Generated static members such as `API.messages.list` carry an immutable backend address and the associated types. Public call methods infer both types from that reference.

| Operation                  | Accepted reference | Result                                        |
| -------------------------- | ------------------ | --------------------------------------------- |
| `fetch(_:arguments:)`      | Query              | One decoded output, asynchronously.           |
| `subscribe(to:arguments:)` | Query              | A throwing async sequence of query snapshots. |
| `mutate(_:arguments:)`     | Mutation           | One decoded output, asynchronously.           |
| `run(_:arguments:)`        | Action             | One decoded output, asynchronously.           |

No result-type parameter or unconstrained generic return lets callers reinterpret a function. No-argument functions receive overloads without an `arguments:` label. Argument initializers require all required properties and give only genuinely optional properties an omission default. A required nullable property still requires an explicit argument.

Reference construction must be public enough for generated code in a consumer module. Any manual construction is labeled unchecked and documented as bypassing contract verification; ordinary APIs do not accept raw strings. The type-safety guarantee applies to generated references, just as an explicit cast can bypass TypeScript's generated contract.

Use UpperCamelCase for types and lowerCamelCase for values, parameters, and namespace properties. Preserve module nesting and backend export vocabulary. Normalize acronym spellings deliberately, such as `channelID`, and retain an exact wire-name map. Escape Swift keywords and string literals. Detect normalization collisions, including case-insensitive file-name collisions, and require an explicit name override; do not add unstable numeric suffixes.

The root namespace is configurable so an application can import contracts for more than one backend. Naming overrides change Swift spelling only, never routing or wire keys. Generated declarations carry documentation describing units, presence semantics, and the backend source location.

### 5. Reuse the official transport and define lifetime semantics

`TypedConvexClient` wraps an existing `ConvexMobile.ConvexClient`, including the SDK's authenticated client subclass, so existing login, token refresh, logout, and connection state remain owned by the same SDK instance. Propose a main-actor-isolated wrapper; generated immutable models are `Sendable`. The SDK client itself has no `Sendable` conformance. Main-actor isolation alone is not yet proven sufficient across its nonisolated async methods. Establish a compiler-checked ownership boundary, including any necessary upstream annotations, before finalizing this API. Do not silence diagnostics with `@preconcurrency`, unchecked conformances, or unsafe isolation annotations.

Keep the codec bridge behind this adapter. The SDK accepts `[String: ConvexEncodable?]`, whose values implement `convexEncode() throws -> String`, and decodes results through an unconfigurable `JSONDecoder`. Supply our own argument-value conformers and generated/custom `Decodable` implementations through those public extension points. A missing argument key means omission; a present null-encoding value means null. Nested object keys must be escaped by our encoder, not interpolated into JSON.

Decode scalar envelopes directly at every nesting level, without depending on the SDK's numeric property wrappers or Foundation's default `Data` representation. Always select the generic mutation/action overload, including for `ConvexNull`; the SDK's void overload independently decodes a `String?`. Avoid a generic JSON-tree allocation and encode/decode/encode round-trip for statically generated values. The per-argument JSON strings required by the SDK are an unavoidable adapter cost.

The inspected SDK has no public one-shot query on the existing client. Once the upstream subscription prerequisite is resolved, `fetch` owns a subscription, returns its first result, and cancels it on success, failure, or task cancellation. A null result is a result, not an absence of an event. Fetching once does not introduce a second HTTP transport or claim a transaction shared with other queries. It must also work when another subscriber already has the same query cached.

`subscribe` returns a `QuerySubscription<Output>` async sequence with explicit `cancel()`. Each iterator owns its underlying subscription; task cancellation, iterator release, explicit cancellation, and terminal error tear it down. Registration/cancellation races must cancel a subscription even if its SDK token arrives after cancellation. A retained subscription may outlive an early loop exit, so the documented pattern uses `defer` when deterministic teardown is needed.

Query updates are snapshots, not an event log. Use a bounded newest-snapshot buffer and document coalescing for a slow consumer. Reconnection and authentication transitions follow the SDK; a publisher's terminal error remains terminal, with explicit resubscription by the caller. Do not turn failures into empty collections or invent automatic action retries. The inspected SDK does not propagate Swift task cancellation into mutation/action execution. Initially, cancellation of those calls does not promise prompt completion or server abort; it never implies rollback.

Use ordinary `async throws`; transport failures and user-thrown `ConvexError` payloads are not a statically enumerated TypeScript throws contract. Preserve the server payload available through the SDK and distinguish contract-decoding failures with endpoint and coding-path context. The SDK flattens thrown subscription decoding errors into a message, so use an internal `Decodable` outcome envelope that captures decoding success or failure as a value; the adapter then surfaces the original failure. This avoids claiming diagnostic information the SDK otherwise discards. Avoid logging argument values, response bodies, or credentials by default.

### 6. Give plugins and macros separate responsibilities

The Swift executable `convex-swift-codegen` reads only a local contract and local naming configuration. A thin `ConvexGenerate` build tool plugin invokes it using a build command with declared inputs and outputs. Start with one known output file per generated target to keep invalidation and stale-output removal predictable. Write only to the plugin work directory; never modify package sources during a build.

The explicit `generate-convex` command plugin invokes the same generator for teams that commit generated source. It requests source-write permission and supports checking without writing. These are alternative workflows per target: checked-in declarations must not also be generated into that target by the build plugin.

Proposed workflow:

```sh
# Backend CI or development, using the lockfile-installed exporter.
convex-swift-export --project convex/tsconfig.json --output contracts/convex-contract.json
convex-swift-export --project convex/tsconfig.json --output contracts/convex-contract.json --check

# Swift consumer choosing checked-in generation instead of the build plugin.
swift package --allow-writing-to-package-directory generate-convex
swift package generate-convex --check
```

These command names are proposed. Neither Swift plugin installs or invokes Node, accesses a deployment, or needs a deploy key. The exporter is a backend development dependency. A contract can be copied or published between repositories; only its local snapshot is read during Swift generation.

Provide SwiftPM package-target integration and Xcode build-tool integration through the appropriate plugin host APIs. Also support generating a standalone Swift contract package consumed by an Xcode application; this avoids requiring every application target to host a generator. Test both hosts, including a clean build, incremental regeneration, and file removal.

Do not require macros in the first generated-client implementation. The generator already knows every property and can emit complete, inspectable declarations. Expanding a second layer of macros would add a SwiftSyntax dependency and another diagnostic boundary without recovering more backend information. An optional `@ConvexModel` macro could later share coding synthesis for handwritten models, but it would not verify backend equivalence and is outside this proposal's delivery scope.

### 7. Adapt the package template at implementation time

Use `swift-convex` as the package identity and `SwiftConvex` as the initial public runtime product/module, avoiding a module-name collision with `ConvexMobile`. Keep the manifest at the repository root. Add the generator executable, build plugin, and command plugin as separate targets because they run on the build host rather than in the application.

Keep the exporter under `tools/contract-exporter/` with its own locked backend-tool dependencies and extraction fixtures. It introduces TypeScript/Node to the development workflow, not to the runtime library or ordinary Swift application build. Distribution/versioning of the exporter and its format compatibility must be coordinated with the Swift generator.

Start the transport-backed product with arm64 iOS device/simulator and arm64 macOS support. The template's iOS 17 and macOS 14 floors exceed the inspected SDK's declared floors and remain the proposed application floors. Intel Mac/simulator, universal Mac, Catalyst, Linux, watchOS, tvOS, and visionOS are unsupported by the inspected binary distribution. Do not inherit claims for them from the template. Keep the generator target graph independent of `ConvexMobile`; portable generator checks do not establish transport portability.

After approval, instantiate and adapt the remaining template tooling: Swift 6.4 tools mode, strict concurrency, Swift Testing, public DocC, external consumer tests, mise/hk formatting and gates, and Knope's single-package `v<version>` tags. Select and lock compatible SDK/compiler versions through the feasibility work. Do not ship the template's example library as a placeholder product.

Record the supported SDK release range, binary architecture matrix, and upstream-fix provenance before publishing. The SDK is Apache-2.0 licensed and bundles Rust code; review required notices and binary redistribution obligations. No project license or public release is established by this draft.

[README.md](../README.md) gains verified installation and generation instructions only when they work. [VISION.md](../VISION.md) gains an implementation claim only after acceptance. The codec, generation format, and compatibility matrix need current reference documentation when implementation starts; they presently have no source outside this draft. No architecture decision is marked accepted in this change.

### 8. Prove the contract before release

Implementation proceeds through these dependent proofs, all within the proposal's scope:

1. Extract a representative backend containing an inferred result without a return validator, a schema document, a branded ID, optional/null fields, a union, and all three callable function kinds. Compare the resolved exported contract with TypeScript's public helper types. Establish the supported compiler/Convex versions.
2. Establish a supported SDK revision that fixes the reported publisher races and permits a safe Swift 6 ownership boundary. Then round-trip each supported Convex scalar and composite through its public interfaces: Int64 boundaries, nonfinite doubles, signed zero, bytes, omitted versus null fields, escaped object keys, nested arrays/records, and malformed payloads. A narrower SDK path is a blocker to the advertised value set, not permission to weaken types silently.
3. Compile an external Swift consumer against generated declarations. Wrong argument labels/types, missing required fields, wrong-table IDs, wrong operation kind, and references to internal functions must fail compilation for the intended reason. Regeneration after backend changes must update or remove the corresponding declarations.
4. Exercise plugin and runtime behavior: deterministic generation, unsupported-type diagnostics, stale artifact detection, clean offline generation after dependency resolution, Xcode/SwiftPM builds, authentication, live query updates, one-shot fetch, task cancellation, and subscription teardown against a disposable backend.

Use Swift Testing and the template's real tagged-dependency `Consumer/` harness for public API verification. Snapshot tests supplement compiled consumers; they cannot establish type safety alone. Backend integration checks run in an explicitly configured CI job with isolated test data and secrets, never as part of a consumer's build plugin.

## Compatibility

There are no existing users of this package. Adoption wraps the existing SDK client; it does not require renaming backend functions or changing stored documents. Existing string-based calls can coexist while an application migrates, but they remain outside the typed guarantee.

Type safety is relative to the generated snapshot and supported value set. It cannot prove deployment freshness, authorization, ID existence, server business rules, or correctness of a backend type assertion. A deployed incompatible change may still cause a runtime decoding or routing error.

Backend CI checks snapshot freshness. Swift CI checks snapshot-to-source consistency. A consumer without backend source cannot independently prove that a snapshot matches the deployment. A fingerprint records provenance; it is not a server attestation. Support additive server fields during decoding where the declared shape permits them, while rejecting missing required fields, invalid known values, and unknown closed-union tags.

## Implications on adoption

Backend maintainers run a pinned exporter and distribute the resulting contract. Swift developers add the runtime plus either a build plugin or generated sources. They stop maintaining parallel endpoint dictionaries and result structs for adopted functions, and adapt to nominal types where TypeScript previously allowed structural assignment.

The cost is a backend tooling dependency and generated-artifact review. The benefit is preserving inferred contracts without requiring return validators everywhere. Plugin-based generation removes generated-source churn; checked-in generation makes declarations directly reviewable. Both paths use the same intermediate contract and emitter.

## Scope

This proposal defines one coherent feature: a generated, typed client boundary backed by the official Swift SDK. Its delivery includes the semantic exporter, intermediate format, value codecs, nominal models/references, typed operations and subscriptions, generator, both plugin workflows, compatibility documentation, and the proofs above.

This commit delivers the proposal and template-derived documentation foundation only. Implementation requires the human to settle the proposal and move it to `awaiting-implementation`.

### Out of scope

- A new networking/sync engine or a Linux transport, because preserving Convex runtime semantics is already the SDK's responsibility.
- Swift backend authoring, internal/admin function execution, and HTTP action client generation, because those are different contracts from the public generated Convex API.
- SwiftUI wrappers, optimistic-update caches, and automatic pagination controllers, because they add state-management behavior beyond typed function calls. Pagination-shaped arguments and results remain ordinary supported contracts.
- Mandatory macros or handwritten schema DSLs, because neither is needed to derive this contract and both create another representation to maintain.
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
| Run TypeScript discovery inside a Swift build plugin | One apparent build step in a monorepo.                                                     | Couples Swift builds to Node, backend source/configuration, and potentially deployment work. Reject for reproducibility and separate-repository use.                                    |

## Open questions

- [NEEDS CLARIFICATION: Approve the recommended source-semantic exporter and local-contract workflow, accepting a backend TypeScript tooling dependency, or prefer a validator-required deployment export with explicitly reduced inference parity?]
- [NEEDS CLARIFICATION: Approve the proposed initial boundary of arm64 iOS/macOS transport support and no mandatory macros, or identify an additional platform or macro use case that must be part of the first supported contract?]

The codec and compiler-version feasibility items are engineering proofs, not questions the user must answer from memory. They remain implementation gates; their failure requires an explicit design revision.
