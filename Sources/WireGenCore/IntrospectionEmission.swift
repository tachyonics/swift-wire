/// Emission of the graph's `introspect() -> WiringModel` method — the compile-time-baked,
/// read-only view of the graph (Wire is compile-time DI, so there's no runtime reflection).
/// Split out of `CodeEmission.swift` (file-length) but part of the same `renderWireGraph`
/// pipeline; the shared `propertyName` helper lives there.

/// The `func introspect() -> WiringModel` emitted on the graph struct: a read-only
/// view of the graph, baked in at codegen (Wire is compile-time DI, so no runtime
/// reflection). One `BindingInfo` per binding in construction order.
func introspectionMethodLines(_ topologicalOrder: [DiscoveredBinding]) -> [String] {
    var lines: [String] = []
    lines.append("")
    lines.append("    func introspect() -> WiringModel {")
    if topologicalOrder.isEmpty {
        lines.append("        WiringModel(bindings: [])")
    } else {
        lines.append("        WiringModel(bindings: [")
        for binding in topologicalOrder {
            lines.append("            \(bindingInfoLiteral(binding)),")
        }
        lines.append("        ])")
    }
    lines.append("    }")
    return lines
}

/// A `BindingInfo(...)` literal for one binding — bound type, key, kind, scope, and
/// dependency edges (for an aggregate, `binding.dependencies` surfaces the contributors).
private func bindingInfoLiteral(_ binding: DiscoveredBinding) -> String {
    let (kind, scope) = introspectionKindAndScope(binding)
    let dependencies = binding.dependencies
        .map {
            "DependencyEdge(type: \(swiftStringLiteral($0.type)), "
                + "key: \(optionalSwiftStringLiteral($0.keyIdentifier)))"
        }
        .joined(separator: ", ")
    let location = binding.location
    let locationLiteral =
        "SourceLocation(module: \(swiftStringLiteral(binding.originModule)), "
        + "file: \(swiftStringLiteral(location.file)), line: \(location.line))"
    return "BindingInfo("
        + "type: \(swiftStringLiteral(binding.boundType)), "
        + "key: \(optionalSwiftStringLiteral(binding.keyIdentifier)), "
        + "kind: .\(kind), "
        + "scope: \(optionalSwiftStringLiteral(scope)), "
        + "dependencies: [\(dependencies)], "
        + "location: \(locationLiteral))"
}

/// The `BindingKind` case name and scope seed for a binding: a scoped type binding
/// carries its seed; a plain `@Singleton` is app-scoped (nil seed).
private func introspectionKindAndScope(_ binding: DiscoveredBinding) -> (kind: String, scope: String?) {
    switch binding {
    case .scopeBound(let type):
        if let seed = type.scopeKey?.seed { return ("scoped", seed) }
        return ("singleton", nil)
    case .provider(let provider):
        return ("provider", provider.scopeKey?.seed)
    case .aggregate:
        return ("aggregate", nil)
    }
}

/// A Swift string literal for a type name. Type names from SwiftSyntax hold only type
/// syntax (`<`, `>`, `[`, `&`, `.`, spaces) — never a quote or backslash — so no
/// escaping is needed.
private func swiftStringLiteral(_ value: String) -> String {
    "\"\(value)\""
}

private func optionalSwiftStringLiteral(_ value: String?) -> String {
    value.map(swiftStringLiteral) ?? "nil"
}
