# Composition harness (iteration 7g)

The two-package integration gate for Wire's multi-module composition. It
lives here, **outside `swift test`**, on purpose: the harness library uses
Wire's macros, so it depends on `swift-wire` — and a fixture package that
`swift-wire`'s own test targets depended on would form a **circular
package dependency**. So the external-`.product` activation path (which
can't be reached from a same-package sibling target) is exercised by a
separate consumer + library pair that depend on `swift-wire` one-way.

```
CompositionHarness/
├── Library/    — an external Wire-aware library package (depends on swift-wire)
│                 _WireExports.swift marker + a public @Singleton + a public keyed @Provides
├── Consumer/   — depends on swift-wire + Library, applies WireBuildPlugin;
│                 an executable that bootstraps the generated graph and asserts
│                 the library's bindings composed across the package boundary
└── run-harness.sh — runs the gate (the CompositionHarness CI job invokes this)
```

## Running

```
./CompositionHarness/run-harness.sh
```

It builds the consumer — whose `WireBuildPlugin` re-parses and composes the
external `WireHarnessLibrary` (activation = the dependency, 7d) — and runs
it: `main.swift` bootstraps `_WireGraph` and asserts the unkeyed and keyed
`ExternalService` bindings resolved. This validates, end-to-end across a
package boundary: external `.product` activation (7d), the foreign
`import` in generated code (7c), and cross-module key resolution (7a/7f).

The root `swift-wire` package does not reference this directory, so
`swift build` / `swift test` ignore it entirely.
