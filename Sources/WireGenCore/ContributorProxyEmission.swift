// Contributor-proxy emission — the *structural half* of a plugin-generated contributor proxy (Phase A).
//
// `ContributorProxySynthesis` builds the proxy *binding* (how the graph constructs the proxy: a
// scope-bound `<prefix><Subject>` depending on the subject + its demanded factories). This file emits
// the proxy *type* — the `struct` declaration itself — which today the adapter's macro emits in the
// subject's module (forcing library mode). Moving type emission here lets the proxy be declared in the
// consumer module beside the graph, retiring library mode.
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
package func renderContributorProxyDeclaration(_ proxy: DiscoveredScopeBoundType) -> String {
    // Access mirrors the subject's (public/package/internal): the graph consumer — another module in the
    // consumer-module model — constructs the proxy, so a `public` subject's proxy stays `public`, and
    // its memberwise init would otherwise be `internal`, hence the explicit init below.
    let access = proxy.accessLevel.factoryDeclarationPrefix
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
        let fieldName = dependency.name ?? contributorProxySubjectFieldName
        fields.append("\(access)let \(fieldName): \(dependency.type)")
        // Unlabelled (subject) → `_ name`; labelled (factory) → `name`.
        let parameter =
            dependency.name == nil
            ? "_ \(fieldName): \(dependency.type)"
            : "\(fieldName): \(dependency.type)"
        initParameters.append(parameter)
        assignments.append("self.\(fieldName) = \(fieldName)")
    }

    var lines: [String] = []
    // `Sendable` (structural — a proxy holds graph bindings, all `Sendable` in Wire's model). The
    // adapter protocol conformance (`RouteContributor`) is NOT stated here — it arrives with the witness
    // in the domain tool's extension, in this same module.
    lines.append("\(access)struct \(proxy.typeName)\(genericClause): Sendable\(whereClause) {")
    for field in fields {
        lines.append("    \(field)")
    }
    lines.append("    \(access)init(\(initParameters.joined(separator: ", "))) {")
    for assignment in assignments {
        lines.append("        \(assignment)")
    }
    lines.append("    }")
    // Body hole: the witness method (and the adapter-protocol conformance) are emitted by the domain
    // codegen tool as an `extension` on this type, in the same module, referencing the fields above.
    lines.append("}")
    return lines.joined(separator: "\n")
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
