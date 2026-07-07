// Emission of graph conformances — `extension _WireGraph: <Protocol>` for each
// discovered `WireGraphConformanceV1` declaration. Each member maps to the
// aggregate binding for its multibinding key; the aggregate's product type is
// spelled explicitly so the protocol's associated types are inferred from the
// witnesses (e.g. a `Context` associated type from a `[any RouteContributor<Ctx>]`
// member). Wire knows nothing about what the protocol means.

/// Emit `extension _WireGraph: <Protocol> { … }` for each conformance, mapping each
/// member to the default graph's aggregate binding for its key. A member whose key
/// has *no* contributors in this graph maps to an empty collection (`[]` / `[:]`), so
/// the conformance holds even when the consumer contributes nothing — an adapter's
/// `apply` then works whether or not this particular graph feeds it. The imports the
/// referenced protocol and element types need are collected upstream (a conformance is
/// an import source, like a binding — see `WireGen`).
func appendGraphConformances(
    _ conformances: [DiscoveredGraphConformance],
    topologicalOrder: [DiscoveredBinding],
    multibindingKeys: [DiscoveredMultibindingKey],
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
    // Keys by reference, so a member whose key has no aggregate (no contributors)
    // still resolves its collection type for an empty accessor.
    var keysByReference: [String: DiscoveredMultibindingKey] = [:]
    for key in multibindingKeys {
        keysByReference[key.keyReference] = key
    }

    for conformance in conformances {
        lines.append("")
        lines.append("extension _WireGraph: \(conformance.protocolName) {")
        for member in conformance.members {
            if let aggregate = aggregatesByKey[member.keyReference] {
                lines.append(
                    "    var \(member.name): \(aggregate.boundTypeReference) "
                        + "{ self.\(propertyName(for: aggregate)) }"
                )
            } else if let accessor = emptyMemberAccessor(
                member: member,
                key: keysByReference[member.keyReference]
            ) {
                lines.append(accessor)
            }
            // A member whose key is unknown, or a `BuilderKey` (an empty fold has no
            // defined result), can't form an empty value — it's skipped, and the
            // incomplete conformance surfaces as a compile error rather than silently
            // wrong output.
        }
        lines.append("}")
    }
}

/// The `var <name>: <collectionType> { <empty> }` accessor for a member whose key has
/// no contributors in this graph — an empty `[]` for a `CollectedKey`, `[:]` for a
/// `MappedKey`. Returns `nil` for a `BuilderKey` or an unknown key (no well-defined
/// empty value). Mirrors `aggregateShape`'s collected/mapped type derivation.
private func emptyMemberAccessor(
    member: DiscoveredGraphConformance.Member,
    key: DiscoveredMultibindingKey?
) -> String? {
    guard let key else { return nil }
    switch (key.flavour, key.typeArguments) {
    case (.collected, let arguments) where arguments.count == 1:
        return "    var \(member.name): [\(arguments[0])] { [] }"
    case (.mapped, let arguments) where arguments.count == 2:
        return "    var \(member.name): [\(arguments[0]): \(arguments[1])] { [:] }"
    default:
        return nil
    }
}
