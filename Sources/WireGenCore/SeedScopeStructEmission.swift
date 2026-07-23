// Seed-scope struct + bootstrap emission — the `_<Suffix>WireScope` value type a `@Scoped(seed:)` graph
// builds per request, and the `_wireBootstrap<Suffix>Scope` free function that constructs it. Split out of
// `CodeEmission` to keep that file within the line budget; the shared per-binding emitters
// (`constructionExpression`, `propertyName`, `renderMemberInjections`, `wireGraphFieldType`) stay there.

/// Emit one `_<Suffix>WireScope` struct + matching `_wireBootstrap<Suffix>Scope` free function pair. The
/// bootstrap takes `(seed:, wireGraph:)` parameters. Borrowed singleton bindings in the topological order
/// are not declared as locals — each borrow's `accessPath` (`<wireGraphLocal>.<prop>`) is inlined at every
/// consumer's arg site via the `resolvingLocal` hook on `renderArguments`. The synthetic seed binding
/// shadow-binds from the parameter (`let X = X`) and is skipped via the `local != construction` check. Net
/// result: only scope-bound bindings emit `let` lines, borrowed singletons appear at use sites only, and
/// unused borrows produce no output.
func appendSeedScopeStruct(
    scope: SeedScopeEmission,
    parentGraphTypeReference: String,
    into lines: inout [String],
    entries: inout [BootstrapEntry]
) {
    let structName = "_\(scope.identifierSuffix)WireScope"
    let bootstrapFunction = "_wireBootstrap\(scope.identifierSuffix)Scope"
    let storedBindings = scope.topologicalOrder.filter {
        !scope.borrowedBindingPropertyNames.contains(propertyName(for: $0))
    }
    // Both bootstrap parameters use type-anchored labels rather than
    // role-anchored ones. The seed parameter keeps `seed:` as its
    // external label (the role here is fixed) but uses the seed
    // type's property-name form as its internal name. The wire-graph
    // parameter's external label is the parent-graph type's stripped
    // lowerCamel form (`wireGraph:` for `_WireGraph`,
    // `testContainerWireGraph:` for `_TestContainerWireGraph`) so
    // varying parent-graph types don't share the same label. Its
    // internal name is that external label prefixed with `_` so a
    // user binding whose property name resolves to `wireGraph` or
    // `testContainerWireGraph` can coexist without colliding on the
    // local-variable token inside the bootstrap body.
    let seedLocal = identifierName(forType: scope.seedTypeExpression, key: nil)
    let wireGraphExternal = wireGraphParameterLabel(forType: scope.parentGraphType)
    let wireGraphInternal = wireGraphParameterInternalName(forType: scope.parentGraphType)

    let lift = seedScopeLift(
        structName: structName,
        storedBindings: storedBindings,
        parentGraphType: scope.parentGraphType,
        parentGraphTypeReference: parentGraphTypeReference
    )

    // A test-graph variant threads a `doubles` value in alongside the seed and wire graph: the scope
    // holds one or more `@BindType`d bindings whose construction reads `doubles.<field>`, so the bootstrap
    // grows a `doubles:` parameter (internal name `doubles`, matching those access paths). A production
    // scope carries no doubles type, so the parameter and its forwarding are omitted — its emission is
    // unchanged.
    let doublesParameter = scope.doublesType.map { ", doubles: \($0)" } ?? ""
    let doublesForward = scope.doublesType == nil ? "" : ", doubles: doubles"

    // The seed scope's bootstrap entry point on the `Wire` façade — keeps the
    // `(seed:, <parentGraph>:)` parameter shape (opaque-erased), forwarding to the private free function.
    entries.append(
        BootstrapEntry(
            signature:
                "bootstrap\(scope.identifierSuffix)Scope(seed: \(scope.seedTypeExpression), \(wireGraphExternal): \(parentGraphTypeReference)\(doublesParameter)) async throws -> \(lift.openStructReference)",
            body:
                "try await \(bootstrapFunction)(seed: seed, \(wireGraphExternal): \(wireGraphExternal)\(doublesForward))"
        )
    )

    // Borrowed-singleton bindings get inlined at their consumers' arg
    // sites rather than declared as locals — every consumer in the
    // topo order resolves a borrow dep directly to the wire-graph
    // expression (`_WireGraph.logger`). The map's keys are borrow
    // property names; values are the substitution expressions read
    // straight off each borrow's `accessPath`. Unused borrows produce
    // no output: their let-lines are skipped and no consumer refers
    // to them, so they vanish from the emitted bootstrap.
    var borrowAccessPaths: [String: String] = [:]
    for binding in scope.topologicalOrder {
        let name = propertyName(for: binding)
        guard scope.borrowedBindingPropertyNames.contains(name),
            case .provider(let provider) = binding
        else { continue }
        borrowAccessPaths[name] = provider.accessPath
    }
    let resolveBorrow: (String) -> String? = { borrowAccessPaths[$0] }

    lines.append("")
    // No explicit `Sendable` conformance — Swift auto-derives it when
    // every stored binding is itself `Sendable` (the dominant case:
    // every server-side `@Singleton` / `@Provides` binding is
    // typically Sendable). When a binding *isn't* Sendable (e.g. a
    // class with `weak var` that's neither `@MainActor` nor
    // `@unchecked Sendable`), the struct is non-Sendable too, and
    // the compiler surfaces that at the *use site* (where the user
    // tries to cross an isolation boundary) rather than at the
    // generated struct declaration. Right place for the trade-off:
    // the user chose the binding's isolation story, Wire respects it.
    lines.append("internal struct \(structName)\(lift.genericClause) {")
    for binding in storedBindings {
        let property = propertyName(for: binding)
        lines.append(
            "    let \(property): \(wireGraphFieldType(for: binding, liftedParameterForIdentity: lift.parameterForIdentity))"
        )
    }
    lines.append("}")

    lines.append("")
    lines.append(
        "private func \(bootstrapFunction)\(lift.genericClause)(seed \(seedLocal): \(scope.seedTypeExpression), \(wireGraphExternal) \(wireGraphInternal): \(lift.parentGraphLifted)\(doublesParameter)) async throws -> \(lift.openStructReference) {"
    )

    if scope.topologicalOrder.isEmpty && storedBindings.isEmpty {
        lines.append("    \(structName)()")
        lines.append("}")
        return
    }

    // Rule 3 — a promoted producer that is *borrowed* has no let-line here
    // (borrows are inlined at arg sites), so its alias binds up front off the
    // borrow's access path; the rest hang off their own construction line below.
    let aliases = scopeExistentialAliasPlan(scope, constructedHere: scope.topologicalOrder)
    for alias in aliases.upFront {
        let producer = alias.producerLocalName
        lines.append(contentsOf: existentialAliasLines(alias, boundTo: resolveBorrow(producer) ?? producer))
    }

    for binding in scope.topologicalOrder {
        let local = propertyName(for: binding)
        // Borrows are inlined at their consumers' arg sites — no let-
        // line is needed (or wanted: unused borrows would otherwise
        // leave dead lines in the emitted bootstrap).
        if scope.borrowedBindingPropertyNames.contains(local) { continue }
        let construction = constructionExpression(for: binding, resolvingLocal: resolveBorrow)
        // Skip a redundant `let X = X` shadow: it happens when the
        // construction expression equals the local name, which inside
        // the seed bootstrap means the synthetic seed binding whose
        // access path is the parameter's internal name. Subsequent
        // bare references resolve to the parameter directly. The same
        // shadow on a module-scope provider would cross from module
        // scope into the function — that path stays in `appendStruct`
        // and isn't affected.
        guard local != construction else { continue }
        lines.append("    let \(local) = \(construction)")
        lines.append(contentsOf: existentialAliasLines(aliases.afterConstruction[binding.identity], boundTo: local))
    }

    // Post-init member injection block for bindings constructed in
    // this scope. Borrowed bindings are skipped — their post-init
    // wiring (if any) belongs to the scope that owns them. Member
    // injection parameters pointing at a borrowed target route
    // through `resolveBorrow` so the assignment / method call uses
    // the borrow's access path (`_WireGraph.logger`) rather than a
    // non-existent local.
    lines.append(
        contentsOf: renderMemberInjections(
            for: scope.topologicalOrder,
            resolvingLocal: resolveBorrow,
            skipConsumers: scope.borrowedBindingPropertyNames
        )
    )

    let returnArgs = storedBindings.map { binding -> String in
        let name = propertyName(for: binding)
        return "\(name): \(name)"
    }.joined(separator: ", ")
    lines.append("    return \(structName)(\(returnArgs))")
    lines.append("}")
}

/// The opaque-lift of a seed scope — mirrors `_WireGraph<T0>`. A *generic* scoped binding stores
/// `MeController<some TodoRepository>`, and `some P` can't be a plain struct field, so every opaque axis
/// the stored bindings use is lifted to a generic parameter `T0`. The private bootstrap threads the same
/// parameter through its wire-graph argument (`_WireGraph<T0>`); the façade keeps the opaque-erased shape.
private struct SeedScopeLift {
    /// `<T0: TodoRepository>`, or `""` when the scope has no opaque axis.
    let genericClause: String
    /// The parent-graph parameter type with used axes threaded (`_WireGraph<T0>`); unused axes stay opaque.
    let parentGraphLifted: String
    /// The façade's opaque-erased struct reference (`_<S>WireScope<some TodoRepository>`, or the bare name).
    let openStructReference: String
    /// Maps each lifted opaque axis (canonical `some P`) to its parameter (`T0`), for field-type spelling.
    let parameterForIdentity: [String: String]
}

/// Compute the seed scope's opaque-lift from its stored bindings and the parent graph's opaque axes.
private func seedScopeLift(
    structName: String,
    storedBindings: [DiscoveredBinding],
    parentGraphType: String,
    parentGraphTypeReference: String
) -> SeedScopeLift {
    // The opaque axes a stored binding actually uses: a bare `some P` binding, or a generic binding whose
    // determined parameters resolve to `some Constraint` (mirroring `wireGraphFieldType`'s field spelling).
    var usedOpaque: Set<String> = []
    for binding in storedBindings {
        if binding.boundType.hasPrefix("some ") {
            usedOpaque.insert(canonicalTypeName(binding.boundType))
        } else if binding.allGenericParametersDetermined {
            for parameter in binding.genericParameterNames {
                usedOpaque.insert(canonicalTypeName("some \(binding.genericParameterConstraints[parameter] ?? "")"))
            }
        }
    }
    var parameterForIdentity: [String: String] = [:]
    var liftedConstraints: [String] = []
    var parentGraphArguments: [String] = []
    for axis in topLevelGenericArguments(of: parentGraphTypeReference) {
        if axis.hasPrefix("some "), usedOpaque.contains(canonicalTypeName(axis)) {
            let parameter = "T\(liftedConstraints.count)"
            parameterForIdentity[canonicalTypeName(axis)] = parameter
            liftedConstraints.append(String(axis.dropFirst("some ".count)))
            parentGraphArguments.append(parameter)
        } else {
            parentGraphArguments.append(axis)  // an axis the scope doesn't use stays opaque
        }
    }
    let genericClause =
        liftedConstraints.isEmpty
        ? ""
        : "<" + liftedConstraints.enumerated().map { "T\($0.offset): \($0.element)" }.joined(separator: ", ") + ">"
    let parentGraphLifted =
        parentGraphArguments.isEmpty
        ? parentGraphType
        : "\(parentGraphType)<\(parentGraphArguments.joined(separator: ", "))>"
    let openStructReference =
        liftedConstraints.isEmpty
        ? structName
        : "\(structName)<" + liftedConstraints.map { "some \($0)" }.joined(separator: ", ") + ">"
    return SeedScopeLift(
        genericClause: genericClause,
        parentGraphLifted: parentGraphLifted,
        openStructReference: openStructReference,
        parameterForIdentity: parameterForIdentity
    )
}

/// The top-level generic arguments of a type reference (`_WireGraph<some A, Foo<B>>` → `["some A",
/// "Foo<B>"]`); `[]` when there are none. Depth-aware so a nested `<…>` isn't split on its commas.
private func topLevelGenericArguments(of typeReference: String) -> [String] {
    guard let open = typeReference.firstIndex(of: "<"), typeReference.hasSuffix(">") else { return [] }
    let inner = typeReference[typeReference.index(after: open)..<typeReference.index(before: typeReference.endIndex)]
    var arguments: [String] = []
    var current = ""
    var depth = 0
    for character in inner {
        switch character {
        case "<":
            depth += 1
            current.append(character)
        case ">":
            depth -= 1
            current.append(character)
        case "," where depth == 0:
            arguments.append(trimmingSpaces(current))
            current = ""
        default: current.append(character)
        }
    }
    let last = trimmingSpaces(current)
    if !last.isEmpty { arguments.append(last) }
    return arguments
}

/// Strip leading/trailing ASCII spaces (Foundation-free — `trimmingCharacters` isn't available here).
private func trimmingSpaces(_ string: String) -> String {
    var slice = Substring(string)
    while slice.first == " " { slice = slice.dropFirst() }
    while slice.last == " " { slice = slice.dropLast() }
    return String(slice)
}
