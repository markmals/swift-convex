# Swift Convex

`Convex` is a typed Swift client and generator for Convex backends. Generated request values bind function identity, arguments, and output. `ConvexClient` reuses the official Rust runtime; `query(_:)` returns a live Observation model.

The implementation is under review in [PR #1](https://github.com/markmals/swift-convex/pull/1). No Swift library version has been released. The initial runtime supports arm64 iOS 17, iOS Simulator, and macOS 14 with Swift 6.4.

## Preview dependency

Add the review branch while the first library release is pending:

```swift
.package(
    url: "https://github.com/markmals/swift-convex.git",
    branch: "proposal/type-safe-swift-contracts"
)
```

Add `.product(name: "Convex", package: "swift-convex")` to your target. Do not add the official `ConvexMobile` Swift SDK alongside it.

The repository and its native binary artifact are private. SwiftPM needs GitHub read access for both the source repository and `api.github.com`. Configure a private netrc/keychain credential; CLI clients can pass `--netrc-file` to SwiftPM. Never put tokens in a package manifest. Applications download the checksummed native artifact and do not need Rust, Cargo, Node, or a deployment admin key to build.

## Generate the contract

The separate [backend exporter](https://github.com/markmals/convex-contract-exporter) reads TypeScript beside the server and writes runtime-neutral JSON. Its current compatibility pins are TypeScript 5.9.3 and Convex 1.50.0; it does not execute backend modules.

```sh
npx convex-contract-export --project convex/tsconfig.json --output contracts/convex-contract.json
```

Copy or publish that artifact to the Swift project. Add `convex-swift.json` in the consuming target directory:

```json
{
    "contract": "../../Contracts/convex-contract.json",
    "namespace": "API"
}
```

Apply `.plugin(name: "ConvexGenerate", package: "swift-convex")` to that target and exclude the configuration file from ordinary source handling. The plugin generates Swift in its build work directory. For checked-in generation instead, configure `output` and run `swift package --allow-writing-to-package-directory generate-convex`. Use only one workflow per target.

See the [format and naming configuration](guides/contract-format.md) for presence semantics, supported shapes, collision overrides, and drift checking.

## Use generated requests

On the main actor:

```swift
import Convex

let client = ConvexClient(deploymentURL: deploymentURL)
let request = API.Messages.List(channelID: channelID)
let messages = client.query(request)
```

Keep `messages` in stable view state. Reading its `.state` in SwiftUI tracks `.loading`, `.value`, and `.failed` transitions as backend data changes.

- `query(_:)` creates a live `@Observable` model.
- `queryOnce(_:)` performs an async one-shot read.
- `events(for:)` supplies a throwing async sequence of snapshots.
- `mutate(_:)` and `callAction(_:)` accept only their matching request kinds.

The [client guide](guides/using-convex.md) includes a SwiftUI view, cancellation rules, authentication, and typed mutation examples.

## Development

Use Xcode 27.2 or later with Swift 6.4 and the iOS SDK, plus mise:

```sh
mise trust && mise install
mise run native:build
mise run check
```

Maintainer build/test tasks opt into the local native artifact. The external-consumer check deliberately uses the published binary; set `CONVEX_TEST_NETRC` to a private credential-file path when credentials are not in SwiftPM's normal stores.

| Command                     | Verification                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------- |
| `mise run test`             | Contract parsing, generation, wire codecs, client lifetimes, and Observation.                |
| `mise run test:consumer`    | A real version-tagged dependency, generated source, and compiler rejection of invalid calls. |
| `mise run build:platforms`  | Arm64 iOS device and simulator builds.                                                       |
| `mise run docs`             | Public DocC reference with documentation warnings treated as errors.                         |
| `mise run test:integration` | Live generated calls against an explicitly configured disposable backend.                    |
| `mise run native:package`   | Matched native archive, checksum, provenance, and dependency license text.                   |

The [verification guide](guides/verification.md) describes the live fixture and native release workflow. Unit tests require no deployment. Live tests are disabled unless a loopback fixture URL is supplied.

## Project record

This project started from the `swift-package` template at revision `3f40d5d06aa75ebfa7a7535c46b5076e3b773467`, preserving its SwiftPM, Swift Testing, external-consumer, DocC, Workbench, and Knope conventions. Its example library and unsupported platform claims were removed.

See [proposal 0001](proposals/0001-type-safe-swift-contracts.md), the [vision](VISION.md), and [changelog](CHANGELOG.md). Native dependency notices are in [RustRuntime/NOTICE](RustRuntime/NOTICE) and the artifact's `Licenses` directory.
