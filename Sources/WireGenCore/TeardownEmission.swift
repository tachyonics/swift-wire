/// Emission of the graph's `@Teardown` orchestration — the `teardown()` method on the graph
/// struct, the captured `_wireTeardown` closure built in the bootstrap body, and the per-binding
/// call lines they share. Split out of `CodeEmission.swift` (file-length) but part of the same
/// `renderWireGraph` pipeline; the shared `propertyName`/`effectPrefix` helpers live there.
///
/// The load-bearing idea: an `@Singleton(as: P.self)` binding is stored on the graph under a
/// lifted `some P` identity, so its concrete `@Teardown` members aren't visible there. The
/// teardown closure is therefore built at bootstrap — where each binding's local still carries
/// its concrete type — and captured onto the graph, which just runs it.

/// The `func teardown() async -> [any Error]` emitted on the graph struct — the
/// app-scope teardown walk. Calls each `@Teardown` binding's action in **reverse**
/// construction order (dependents before dependencies), collecting rather than
/// propagating errors so one failing action doesn't stop the rest. Emitted only when the
/// graph has at least one teardown action; otherwise the `Teardownable` default (an empty
/// `[]`) stands in, so no method is emitted on a graph with nothing to tear down.
func teardownMethodLines(_ torn: [DiscoveredBinding]) -> [String] {
    guard !torn.isEmpty else { return [] }
    // The teardown actions are captured at bootstrap (`bootstrapTeardownClosureLines`),
    // where the concrete types are live; the graph stores that closure. This method just
    // runs it — necessary because the graph's stored properties may be lifted `some P`
    // and can't name the concrete members the actions call.
    return [
        "",
        "    func teardown() async -> [any Error] {",
        "        await _wireTeardown()",
        "    }",
    ]
}

/// The captured-teardown closure, emitted in the bootstrap body after every binding local
/// is in scope. Each action runs against its binding's *concrete* local rather than the
/// graph's stored property (which may be a lifted `some P`), which is what makes `@Teardown`
/// work on an opaquely-bound `@Singleton(as:)` type. Actions run in reverse construction
/// order (`torn` is already reversed); the closure is `@Sendable` and captured onto the graph's
/// `_wireTeardown` property.
func bootstrapTeardownClosureLines(_ torn: [DiscoveredBinding]) -> [String] {
    guard !torn.isEmpty else { return [] }

    // `errors` is appended to only by a throwing member or a producer action (both wrapped in
    // do/catch). When every teardown is a non-throwing member the array stays empty, so bind it
    // with `let` — a `var` would draw a never-mutated warning in the generated file.
    let mutatesErrors = torn.contains { binding in
        switch binding.teardown?.kind {
        case .member(_, _, let isThrowing): return isThrowing
        case .action: return true
        case nil: return false
        }
    }

    var lines: [String] = [
        "    let _wireTeardown: @Sendable () async -> [any Error] = {",
        "        \(mutatesErrors ? "var" : "let") errors: [any Error] = []",
    ]
    for binding in torn {
        lines.append(contentsOf: teardownCallLines(for: binding))
    }
    lines.append("        return errors")
    lines.append("    }")
    return lines
}

/// The call lines for one binding's teardown action, indented for the captured-teardown
/// closure body. The action runs against the binding's bootstrap *local* (a bare name,
/// concrete type) — not `self.<property>` — so an opaquely-bound type's concrete members
/// stay in reach. A throwing action is wrapped in `do`/`catch` that appends to `errors`;
/// a non-throwing member action needs no wrapping. The producer action coerces to the
/// macro's `@Sendable (T) async throws -> Void` type — pinned via a typed local so a sync,
/// non-throwing action coerces cleanly — and so is always `try await`.
private func teardownCallLines(for binding: DiscoveredBinding) -> [String] {
    guard let action = binding.teardown else { return [] }
    let property = propertyName(for: binding)
    switch action.kind {
    case .member(let methodName, let isAsync, let isThrowing):
        let call = "\(effectPrefix(isAsync: isAsync, isThrowing: isThrowing))\(property).\(methodName)()"
        guard isThrowing else { return ["        \(call)"] }
        return [
            "        do {",
            "            \(call)",
            "        } catch {",
            "            errors.append(error)",
            "        }",
        ]
    case .action(let expression):
        return [
            "        do {",
            "            let action: @Sendable (\(binding.boundTypeReference)) async throws -> Void = \(expression)",
            "            try await action(\(property))",
            "        } catch {",
            "            errors.append(error)",
            "        }",
        ]
    }
}
