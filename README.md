# Swift Convex

`Convex` is a typed Swift client and generator for Convex backends. Generated request values bind function identity, arguments, and output. `ConvexClient` reuses the official Rust runtime; `observe(_:)` returns a live Observation model.

The initial runtime supports arm64 iOS 17, iOS Simulator, and macOS 14 with Swift 6.4.

## Installation

Add the package through Swift Package Manager:

```swift
.package(
    url: "https://github.com/markmals/swift-convex.git",
    from: "0.1.0"
)
```

Add `.product(name: "Convex", package: "swift-convex")` to your target. Do not add the official `ConvexMobile` Swift SDK alongside it.

The source repository and checksummed native artifact are public; package installation needs no GitHub credentials. Applications download the native artifact and do not need Rust, Cargo, Node, or a deployment admin key to build.

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
let messages = client.observe(request)
```

Keep `messages` in stable view state. Reading its `.state` in SwiftUI tracks `.loading`, `.value`, and `.failed` transitions as backend data changes.

- `observe(_:)` creates a live `@Observable` model.
- `fetch(_:)` performs an async one-shot read.
- `snapshots(for:)` supplies a throwing async sequence of snapshots.
- `execute(mutation:)` and `execute(action:)` accept only their matching request kinds.

The [client guide](guides/using-convex.md) includes a SwiftUI view, cancellation rules, authentication, and typed mutation examples.

## Development

Use Xcode 27.2 or later with Swift 6.4 and the iOS SDK, plus mise and [rustup](https://rustup.rs) for native maintainer builds:

```sh
mise trust && mise install
mise run native:build
CONVEX_NATIVE_LOCAL=1 mise run setup
mise run check
```

Maintainer build/test tasks opt into the local native artifact. The external-consumer check deliberately downloads the published binary.

| Command                     | Verification                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------- |
| `mise run test`             | Contract parsing, generation, wire codecs, client lifetimes, and Observation.                |
| `mise run test:consumer`    | A real version-tagged dependency, generated source, and compiler rejection of invalid calls. |
| `mise run build:platforms`  | Arm64 iOS device and simulator builds.                                                       |
| `mise run docs`             | Public DocC reference with documentation warnings treated as errors.                         |
| `mise run test:integration` | Live generated calls against an explicitly configured disposable backend.                    |
| `mise run native:test`      | Rust value validation, cancellation, and authentication boundary tests.                      |
| `mise run native:package`   | Matched native archive, checksum, provenance, and dependency license text.                   |

The [verification guide](guides/verification.md) describes the live fixture and native release workflow. Unit tests require no deployment. Live tests are disabled unless a loopback fixture URL is supplied.

## License

The Swift library and generator are available under the [MIT license](LICENSE). The native Rust bridge retains its [Apache-2.0 license](RustRuntime/LICENSE); third-party components retain their own licenses and notices in [RustRuntime/NOTICE](RustRuntime/NOTICE) and the artifact's `Licenses` directory.

## Project record

This project started from the `swift-package` template at revision `3f40d5d06aa75ebfa7a7535c46b5076e3b773467`, preserving its SwiftPM, Swift Testing, external-consumer, DocC, Workbench, and Knope conventions. Its example library and unsupported platform claims were removed.

See [proposal 0001](proposals/0001-type-safe-swift-contracts.md), the [vision](VISION.md), and [changelog](CHANGELOG.md). Native dependency notices are in [RustRuntime/NOTICE](RustRuntime/NOTICE) and the artifact's `Licenses` directory.
