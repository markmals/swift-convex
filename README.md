# Swift Convex

Swift Convex is a proposed Swift package for calling Convex functions through generated, type-safe Swift APIs. The goal is to preserve the contract available to Convex's TypeScript client while following the Swift API Design Guidelines.

## Start here

- [Proposal 0001: Type-Safe Swift Contracts for Convex](proposals/0001-type-safe-swift-contracts.md): research, proposed API, generation pipeline, tradeoffs, and questions for review.
- [Vision](VISION.md): project intent and boundaries.
- [Proposal lifecycle](proposals/README.md): who decides when implementation can begin.

The proposal is a draft. There is no library, generator, macro, package plugin, release, or installation command yet. API and command examples in the proposal describe the proposed design.

## Template foundation

This repository starts from the proposal and vision conventions in `/Users/orion/Developer/Templates/agentic-projects/swift-package`, inspected at template-repository revision `3f40d5d06aa75ebfa7a7535c46b5076e3b773467`. The proposal follows the `PROPOSAL.md` format supplied by the template's Workbench 3.0.1 dependency. Record-directory indexes and `dprint.json` come from the package template.

Only the documentation foundation is instantiated at this stage. The template's example `SemanticVersion` library, placeholder package manifest, tests, and publishing automation are intentionally absent. Proposal 0001 specifies how to adapt the package scaffold after design approval, including the transport's platform limits and the backend-side TypeScript exporter.

## Document validation

With Workbench 3.0.1 and dprint 0.64.3 available:

```sh
workbench records validate --output text
dprint check
```

These commands validate records and formatting. They do not establish that the proposed Swift API or generator works.
