// Contributor-proxy emission — the *structural half* of a plugin-generated contributor proxy.
//
// `ContributorProxySynthesis` builds the proxy *binding* (how the graph constructs the proxy: a
// scope-bound `<prefix><Subject>` depending on the subject + its demanded factories). This file emits
// the proxy *type* — the `struct` declaration itself — into the consumer module, beside the graph.
//
// What's emitted is deliberately only the STRUCTURAL half: the stored fields (the subject +
// each lifted factory), the initialiser the graph's construction call targets, and `Sendable`. There
// is a **body hole** — no adapter-protocol conformance, no witness method. A domain codegen tool (an
// adapter's, e.g. WireMVC's route generator) fills the hole with an `extension` in the same module,
// meeting this struct only on the deterministic field names below. WireGen stays domain-free: it emits
// fields and a hole; it never learns what the witness does.
//
// The field-name contract — shared with the domain body generator, the successor to the old
// macro↔plugin handshake:
//   • the subject is stored as `_wireSubject` (its dependency is positional/unlabelled, so the graph
//     names no member — only the domain body references it, by this name);
//   • each lifted factory is stored as `_wireFactory_<sanitized key>` (see `factoryDependencyName`).

/// The stored-property name the emitted proxy holds its subject under. The subject dependency is
/// positional (unlabelled) in the graph's construction call — the graph names no member of the proxy —
/// so this name exists only as the contract the domain witness body references (`self._wireSubject`).
/// Domain-neutral and `_wire`-prefixed, like `_wireFactory_<key>`, so it can't collide with user code.
package let contributorProxySubjectFieldName = "_wireSubject"

/// The stored-property name a **bridging** proxy holds its scope-entry thunk under, in place of
/// `_wireSubject` — for a proxy whose subject is narrower-scoped than the proxy (a `@Scoped(seed:)`
/// subject under a `.singleton` proxy). The thunk `(Seed) async throws -> Subject` constructs the
/// subject fresh in the subject's scope; the domain witness body invokes it per request. Labelled,
/// so the emitted proxy stores/inits it by this name (unlike the positional subject). Its producer is
/// synthesised in M5.4.2; M5.4.1 emits the field.
package let contributorProxyScopeEntryFieldName = "_wireEnterScope"

/// The type of a bridging proxy's scope-entry thunk: `@Sendable (Seed) async throws -> Subject`. One
/// builder shared by the synthesis (which types the `_wireEnterScope` dependency) and the emission
/// (which types the emitted closure and finds its target scope), so the seed/subject contract lives in
/// one place.
package func contributorScopeEntryThunkType(seed: String, subject: String) -> String {
    "@Sendable (\(seed)) async throws -> \(subject)"
}

/// Recover `(seed, subject)` from a thunk type built by `contributorScopeEntryThunkType` — the inverse
/// the emission uses to locate the target seed scope and name the subject it returns. `nil` for a string
/// not in that shape.
package func parsedContributorScopeEntryThunkType(_ type: String) -> (seed: String, subject: String)? {
    let opening = "@Sendable ("
    let middle = ") async throws -> "
    guard type.hasPrefix(opening), let middleRange = type.firstRange(of: middle) else { return nil }
    let seed = String(type[type.index(type.startIndex, offsetBy: opening.count)..<middleRange.lowerBound])
    let subject = String(type[middleRange.upperBound...])
    guard !seed.isEmpty, !subject.isEmpty else { return nil }
    return (seed, subject)
}

/// Render the structural declaration for one contributor-proxy binding — the `struct` with its stored
/// fields + initialiser + `Sendable`, generic exactly as the subject, with a body hole (no conformance,
/// no witness). `proxy` is the fully-formed proxy binding *after* factory synthesis has appended the
/// lifted-factory dependencies, so its `dependencies` are the complete field set: the positional subject
/// first, then each labelled factory (and any adapter-injected dependency).
///
///     public struct _WireRouteContributor_TodosController<Repository: TodoRepository>: Sendable {
///         public let _wireSubject: TodosController<Repository>
///         public let _wireFactory_Keys_backend: _WireFactory_Keys_backend
///         public init(_ _wireSubject: TodosController<Repository>, _wireFactory_Keys_backend: _WireFactory_Keys_backend) {
///             self._wireSubject = _wireSubject
///             self._wireFactory_Keys_backend = _wireFactory_Keys_backend
///         }
///     }
// The proxy is emitted `internal` (no access keyword), never the subject's access. It's a consumer-local
// coordination type — emitted into the consumer module, constructed by that module's graph, consumed only
// there as `any <ContributorProtocol>` — so it is never public API. Emitting it `public` (mirroring a
// `public` subject) would force every type it references to be public *from the consumer*, which fails
// under `InternalImportsByDefault`: the generated file imports a shared controllers library internally, so
// a `public` proxy couldn't expose that library's (public) controller / factory types. `internal`
// sidesteps that — an internal declaration may freely reference internally-imported types.
package func renderContributorProxyDeclaration(_ proxy: DiscoveredScopeBoundType) -> String {
    let genericClause = renderProxyGenericClause(
        names: proxy.genericParameterNames,
        constraints: proxy.genericParameterConstraints
    )
    let whereClause = proxy.genericWhereClause.map { " where \($0)" } ?? ""

    // One stored field + one init parameter + one assignment per dependency, in dependency order. A
    // dependency with no label is the subject (stored as `_wireSubject`, taken positionally so the
    // construction call — which passes it unlabelled — matches); a labelled dependency (each lifted
    // factory) keeps its label as both field name and init label.
    var fields: [String] = []
    var initParameters: [String] = []
    var assignments: [String] = []
    for dependency in proxy.dependencies {
        // Capture dependencies exist only to order the proxy after the singletons its scope-entry thunk
        // captures — they are not stored fields or init parameters (the thunk references the captured
        // locals directly). See `DependencyKind.scopeCapture`.
        if dependency.kind == .scopeCapture { continue }
        let fieldName = dependency.name ?? contributorProxySubjectFieldName
        fields.append("let \(fieldName): \(dependency.type)")
        // The scope-entry thunk is a closure stored on the proxy, so its init parameter is `@escaping`.
        let parameterType =
            dependency.kind == .scopeEntryThunk ? "@escaping \(dependency.type)" : dependency.type
        // Unlabelled (subject) → `_ name`; labelled (factory / scope-entry thunk) → `name`.
        let parameter =
            dependency.name == nil
            ? "_ \(fieldName): \(parameterType)"
            : "\(fieldName): \(parameterType)"
        initParameters.append(parameter)
        assignments.append("self.\(fieldName) = \(fieldName)")
    }

    var lines: [String] = []
    // `Sendable` (structural — a proxy holds graph bindings, all `Sendable` in Wire's model). The
    // adapter protocol conformance (`RouteContributor`) is NOT stated here — it arrives with the witness
    // in the domain tool's extension, in this same module.
    lines.append("struct \(proxy.typeName)\(genericClause): Sendable\(whereClause) {")
    for field in fields {
        lines.append("    \(field)")
    }
    lines.append("    init(\(initParameters.joined(separator: ", "))) {")
    for assignment in assignments {
        lines.append("        \(assignment)")
    }
    lines.append("    }")
    // Body hole: the witness method (and the adapter-protocol conformance) are emitted by the domain
    // codegen tool as an `extension` on this type, in the same module, referencing the fields above.
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// Render the structural declaration for every synthesised contributor proxy, once each — the plugin's
/// Phase-A emission into the consumer graph file. `proxyIdentities` are the qualified names
/// `applyContributorProxies` created; a proxy binding is registered in every partition that consumes it,
/// so it's deduped by qualified name here (the *type* is declared once at module scope, like a factory
/// type). Deterministic order by type name. Reads the proxy bindings *after* factory synthesis, so each
/// carries its complete field set (subject + lifted factories).
package func renderContributorProxyTypes(
    proxyIdentities: Set<String>,
    in allBindings: [Partition: [DiscoveredBinding]]
) -> [String] {
    guard !proxyIdentities.isEmpty else { return [] }
    var proxiesByName: [String: DiscoveredScopeBoundType] = [:]
    for bindings in allBindings.values {
        for binding in bindings {
            guard case .scopeBound(let type) = binding,
                proxyIdentities.contains(type.qualifiedTypeName)
            else { continue }
            proxiesByName[type.qualifiedTypeName] = type  // same type across partitions → one declaration
        }
    }
    return proxiesByName.values
        .sorted { $0.typeName < $1.typeName }
        .map(renderContributorProxyDeclaration)
}

/// The proxy's generic-parameter clause restated from the subject's parameters and per-parameter
/// constraints — `<Repository: TodoRepository>`, or `<A, B: P>` when only some are constrained, or `""`
/// for a non-generic subject. The subject's `where` clause (associated-type / same-type / `~Copyable`
/// requirements) is rendered separately, after the `Sendable` inheritance clause.
private func renderProxyGenericClause(names: [String], constraints: [String: String]) -> String {
    guard !names.isEmpty else { return "" }
    let parameters = names.map { name in
        constraints[name].map { "\(name): \($0)" } ?? name
    }
    return "<\(parameters.joined(separator: ", "))>"
}
