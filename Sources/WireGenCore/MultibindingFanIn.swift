// Fan-in: synthesise one aggregate binding per declared multibinding key
// by collecting the contributions that target it. The aggregate is an
// ordinary `DiscoveredBinding` with a `(collectionType, keyReference)`
// identity and one dependency edge per contributor, so the rest of the
// graph pipeline (split, resolve, topological sort) handles it with no
// special-casing. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 4).

/// Synthesise the aggregate bindings for a module's declared keys.
/// Collected and mapped keys are handled here; builder keys need the
/// builder's result type (read from `buildBlock`), which lands with
/// codegen, so they're skipped for now.
func synthesizeAggregates(
    keys: [DiscoveredMultibindingKey],
    bindings: [DiscoveredBinding]
) -> [DiscoveredBinding] {
    // Index contributions module-wide by the key they target, pairing
    // each with its contributing binding (the graph edge points there).
    var entriesByKey: [String: [ContributorEntry]] = [:]
    for binding in bindings {
        for contribution in binding.contributions {
            entriesByKey[contribution.keyReference, default: []]
                .append(ContributorEntry(binding: binding, contribution: contribution))
        }
    }

    return keys.compactMap { key in
        guard let collectionType = aggregateCollectionType(for: key) else { return nil }
        return .aggregate(
            DiscoveredAggregate(
                keyReference: key.keyReference,
                collectionType: collectionType,
                flavour: key.flavour,
                contributors: orderedContributors(entriesByKey[key.keyReference] ?? []),
                location: key.location
            )
        )
    }
}

private struct ContributorEntry {
    let binding: DiscoveredBinding
    let contribution: Contribution
}

/// The aggregated collection type for a key, or `nil` for flavours/shapes
/// whose type can't be derived from the declaration alone — builder (its
/// result type is read later, with codegen), or a malformed
/// collected/mapped declaration with the wrong generic arity.
private func aggregateCollectionType(for key: DiscoveredMultibindingKey) -> String? {
    switch (key.flavour, key.typeArguments) {
    case (.collected, let arguments) where arguments.count == 1:
        return "[\(arguments[0])]"
    case (.mapped, let arguments) where arguments.count == 2:
        return "[\(arguments[0]): \(arguments[1])]"
    default:
        return nil
    }
}

/// Build aggregate contributors in final order: by `withOrder:` when
/// ranked, otherwise by source location. Step 3 has already rejected
/// mixed and duplicate ranks, so for valid input this is a total order.
/// Each contributor carries a dependency edge whose identity matches the
/// contributing binding's, so the aggregate sorts after it.
private func orderedContributors(_ entries: [ContributorEntry]) -> [AggregateContributor] {
    entries
        .map { entry in
            AggregateContributor(
                dependency: DependencyParameter(
                    name: nil,
                    type: entry.binding.boundType,
                    kind: .injectInitParameter,
                    location: entry.contribution.location,
                    keyIdentifier: entry.binding.keyIdentifier
                ),
                order: entry.contribution.order,
                mapKeyExpression: entry.contribution.mapKeyExpression
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                return lhs.dependency.location < rhs.dependency.location
            }
        }
}
