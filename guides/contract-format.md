---
id: guide.contract-format
title: Convex Contract Format
---

# Convex Contract Format

Format version 1 is the interchange between the separate backend TypeScript exporter and Swift generation. It contains backend names and value semantics, never Swift declarations or naming configuration. The approved behavior is recorded in [proposal 0001](../proposals/0001-type-safe-swift-contracts.md).

## Document

A document has `formatVersion: 1`, `provenance`, `functions`, `tables`, and `types`. `provenance` has string fields `exporterVersion`, `convexVersion`, `typescriptVersion`, and `sourceHash` (a SHA-256 hexadecimal digest). `types` is an object mapping stable backend-derived names to shapes. Every reference must resolve; recursive shape graphs are unsupported and fail validation.

A function has `path` (the exact Convex address), `module` (an array of module path segments), `name` (the backend export name), `kind` (`query`, `mutation`, or `action`), `arguments` (an object shape), `result` (a shape), and `typeSource` (`inferred`, `validator`, or `dynamic`). Its optional `source` has `file` (repository-relative) and `line` (one-based). Only public client-callable functions appear. Sort functions by path and reject duplicate paths.

A table has `name` and `document` (a shape). Sort tables by name. Document shapes include the exact `_id` and `_creationTime` fields; the Swift generator maps those to `id` and `creationTime`. The `_storage` table identity is valid for IDs even when no document shape is exported.

Every statically known document variant must be an object with required `_id` and `_creationTime` fields. `_id` must use that table's ID shape and `_creationTime` must be Float64; named references are resolved before checking them. An explicit `dynamic` position retains its acknowledged loss of static shape rather than inventing fields. Known scalar or collection shapes cannot stand in for table documents.

## Shapes

Every shape is an object with `kind`. Supported forms:

| Kind                                                                | Additional fields                                                                                                  |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `string`, `boolean`, `float64`, `int64`, `bytes`, `null`, `dynamic` | None; `int64` may have `semantic: "commitTimestamp"`.                                                              |
| `id`                                                                | `table`: backend table name.                                                                                       |
| `array`                                                             | `element`: shape.                                                                                                  |
| `object`                                                            | `fields`: array of field definitions, sorted by wire name.                                                         |
| `record`                                                            | `key`: shape restricted to string/ID/string literals or a union of those; `value`: shape.                          |
| `union`                                                             | `variants`: canonical, deduplicated array of shapes. Overlapping variants must normalize or fail Swift generation. |
| `literal`                                                           | `value`: string, boolean, finite JSON number, or a Convex `{"$integer":"base64"}` literal.                         |
| `tuple`                                                             | `elements`: ordered array of shapes; fixed length.                                                                 |
| `ref`                                                               | `name`: a key in `types`.                                                                                          |

An object field has `name` (exact wire key), `type` (shape), and `optional` (boolean). Optionality and nullability are independent: a nullable type is a union containing `{"kind":"null"}`. A required null-valued field remains required. The exporter must not turn optional fields into nullable fields. An explicitly opted-in dynamic position uses `dynamic`; unknown or unrepresentable types fail instead of silently widening.

## Determinism and errors

Canonical output sorts object keys, field definitions, functions, tables, named types, and union variants; array/tuple positions retain order. Source hashes cover source/declaration content, compiler options, exporter options, and dependency locks using repository-relative paths. Exclude timestamps, credentials, deployment tokens, and absolute paths. Writes replace the artifact atomically only after complete validation. `--check` compares the canonical output without writing and exits unsuccessfully on drift.

Unknown format versions, unknown shape kinds, dangling references, duplicate fields/functions/types, recursive shapes, and invalid literal envelopes are errors. An unsupported contract reports its function/type path and original source location when available. The generator does not fetch or execute backend code.

## Swift configuration

Swift naming belongs in a separate target-local `convex-swift.json` configuration. It has `contract` (a path relative to the configuration file), optional `namespace` (default `API`), optional `output` (a path for explicit checked-in generation), and optional `names` (wire-path to Swift-identifier overrides). The build plugin writes a known `Convex.generated.swift` output in its work directory; command generation requires `output`. Neither form modifies the neutral contract.

Name overrides use rendered contract paths, for example `functions[messages:list]` for a request type and `functions[messages:list].arguments[channelId]` for an argument. The build plugin rejects a configured `output` because checked-in output and build-time output must not be compiled into the same target.

The command plugin's `--check` mode does not write, but SwiftPM still requires `--allow-writing-to-package-directory` because plugin permissions are declared statically. Run `convex-swift-codegen --config path/to/convex-swift.json --check` directly when no plugin permission grant is desired.
