// Emission of graph conformances — `extension _WireGraph: <Protocol>` for each
// discovered `WireGraphConformanceV1` declaration. Each member maps to the
// aggregate binding for its multibinding key; the aggregate's product type is
// spelled explicitly so the protocol's associated types are inferred from the
// witnesses (e.g. a `Context` associated type from a `[any RouteContributor<Ctx>]`
// member). Wire knows nothing about what the protocol means.

/// Emit `extension _WireGraph: <Protocol> { … }` for each conformance, mapping
/// each member to the default graph's aggregate binding for its key. A member
/// whose key has no aggregate in this graph is skipped (its absence surfaces as a
/// compile error on the incomplete conformance).
func appendGraphConformances(
    _ conformances: [DiscoveredGraphConformance],
    topologicalOrder: [DiscoveredBinding],
    into lines: inout [String]
) {
    guard !conformances.isEmpty else { return }

    // Aggregate bindings keyed by their multibinding-key reference, so a member's
    // `from:` reference resolves to the graph property carrying that key's product.
    var aggregatesByKey: [String: DiscoveredBinding] = [:]
    for binding in topologicalOrder {
        if case .aggregate = binding, let key = binding.keyIdentifier {
            aggregatesByKey[key] = binding
        }
    }

    for conformance in conformances {
        lines.append("")
        lines.append("extension _WireGraph: \(conformance.protocolName) {")
        for member in conformance.members {
            guard let aggregate = aggregatesByKey[member.keyReference] else { continue }
            lines.append(
                "    var \(member.name): \(aggregate.boundTypeReference) "
                    + "{ self.\(propertyName(for: aggregate)) }"
            )
        }
        lines.append("}")
    }
}
