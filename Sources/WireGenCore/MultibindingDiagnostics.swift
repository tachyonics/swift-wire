import SwiftSyntax

// Iteration 5β validation diagnostics (Step 3). One per-declaration
// check (bare `@Contributes`, run by the visitor) plus the module-wide
// cross-contributor checks (missing key, mixed ordering, duplicate map
// key), run by WireGen after aggregating discovery. The overload set on
// `@Contributes` already enforces per-call argument validity (atKey on
// MappedKey only, withOrder off MappedKey), so the compiler catches
// those — only the cross-declaration rules live here. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 3).

/// A declaration carrying `@Contributes` but no co-located producer macro
/// — the contributor can't be constructed, so the contribution would be
/// silently dropped. `producerMacros` is the set valid at this position:
/// `["Singleton", "Scoped"]` on a type, `["Provides"]` on a var/func.
func strayContributesDiagnostics(
    in attributes: AttributeListSyntax,
    producerMacros: [String],
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard let contributesAttribute = attribute(in: attributes, named: "Contributes") else {
        return []
    }
    if producerMacros.contains(where: { hasAttribute(attributes, named: $0) }) {
        return []
    }
    let producerList = producerMacros.map { "@\($0)" }.joined(separator: " or ")
    return [
        Diagnostic(
            location: makeSourceLocation(
                of: contributesAttribute,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "@Contributes requires a co-located \(producerList) — without a producer macro Wire can't construct the contributor.",
            severity: .error
        )
    ]
}

/// Every cross-contributor multibinding diagnostic. Missing-key is
/// module-wide (a key is declared once); the per-key cross-contributor
/// checks (mixed `withOrder:`, duplicate `atKey:`, duplicate `withOrder:`)
/// run **per partition**, because contributions to the same key in
/// different partitions form separate aggregates and so don't conflict.
/// Output is sorted by source location for stable build output.
package func multibindingContributionDiagnostics(
    declaredKeyReferences: Set<String>,
    contributionsByPartition: [Partition: [Contribution]]
) -> [Diagnostic] {
    var diagnostics = unknownMultibindingKeyDiagnostics(
        contributions: contributionsByPartition.values.flatMap { $0 },
        declaredKeyReferences: declaredKeyReferences
    )
    for partitionContributions in contributionsByPartition.values {
        diagnostics += mixedContributionOrderingDiagnostics(contributions: partitionContributions)
        diagnostics += duplicateMapKeyDiagnostics(contributions: partitionContributions)
        diagnostics += duplicateOrderDiagnostics(contributions: partitionContributions)
    }
    return diagnostics.sorted { $0.location < $1.location }
}

/// `@Contributes(to: X)` where `X` matches no discovered key declaration
/// in the parse set. (The parse set is one module today; it widens under
/// composition — see `MultiModuleComposition.md`.)
package func unknownMultibindingKeyDiagnostics(
    contributions: [Contribution],
    declaredKeyReferences: Set<String>
) -> [Diagnostic] {
    contributions.compactMap { contribution in
        guard !declaredKeyReferences.contains(contribution.keyReference) else { return nil }
        return Diagnostic(
            location: contribution.location,
            message:
                "@Contributes(to: \(contribution.keyReference)) references no multibinding key — declare a 'static let \(contribution.keyReference) = CollectedKey/MappedKey/BuilderKey<…>()' or fix the reference.",
            severity: .error
        )
    }
}

/// Ordering is all-or-none per key: if any contributor specifies
/// `withOrder:`, every contributor to that key must. Flags each unranked
/// contribution in a key that otherwise has ranks.
package func mixedContributionOrderingDiagnostics(
    contributions: [Contribution]
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    for (keyReference, group) in groupedByKey(contributions) {
        let hasRanked = group.contains { $0.order != nil }
        guard hasRanked else { continue }
        for contribution in group where contribution.order == nil {
            diagnostics.append(
                Diagnostic(
                    location: contribution.location,
                    message:
                        "@Contributes(to: \(keyReference)) has no 'withOrder:' but other contributions to '\(keyReference)' do — ordering is all-or-none. Add 'withOrder:' here or drop it from the others.",
                    severity: .error
                )
            )
        }
    }
    return diagnostics
}

/// `atKey:` values must be unique among a `MappedKey`'s contributors — a
/// dictionary literal with duplicate keys is a runtime trap, so it has to
/// be a build-time error.
package func duplicateMapKeyDiagnostics(
    contributions: [Contribution]
) -> [Diagnostic] {
    duplicatePerKeyArgumentDiagnostics(
        contributions: contributions,
        argumentLabel: "atKey",
        uniquenessClause: "map keys must be unique",
        valueOf: { $0.mapKeyExpression }
    )
}

/// `withOrder:` ranks must be unique among a `CollectedKey`/`BuilderKey`'s
/// contributors. Equal ranks leave the tied contributors' relative order
/// undefined; requiring uniqueness keeps "ranked" a strict total order so
/// codegen needs no tiebreak.
package func duplicateOrderDiagnostics(
    contributions: [Contribution]
) -> [Diagnostic] {
    duplicatePerKeyArgumentDiagnostics(
        contributions: contributions,
        argumentLabel: "withOrder",
        uniquenessClause: "contributor ranks must be unique",
        valueOf: { $0.order.map(String.init) }
    )
}

/// Shared duplicate detection for a per-key contribution argument
/// (`atKey:` / `withOrder:`): within each key, the second and later
/// contributions sharing a rendered value get an error, with a note
/// pointing at the first use. Contributions whose value is `nil` (the
/// argument absent) are ignored.
private func duplicatePerKeyArgumentDiagnostics(
    contributions: [Contribution],
    argumentLabel: String,
    uniquenessClause: String,
    valueOf: (Contribution) -> String?
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    for (keyReference, group) in groupedByKey(contributions) {
        var firstByValue: [String: Contribution] = [:]
        for contribution in group.sorted(by: { $0.location < $1.location }) {
            guard let value = valueOf(contribution) else { continue }
            if let first = firstByValue[value] {
                diagnostics.append(
                    Diagnostic(
                        location: contribution.location,
                        message:
                            "duplicate \(argumentLabel): \(value) on '\(keyReference)' — \(uniquenessClause).",
                        notes: [
                            Diagnostic.Note(
                                location: first.location,
                                message: "\(argumentLabel): \(value) first used here"
                            )
                        ],
                        severity: .error
                    )
                )
            } else {
                firstByValue[value] = contribution
            }
        }
    }
    return diagnostics
}

private func groupedByKey(_ contributions: [Contribution]) -> [(String, [Contribution])] {
    var byKey: [String: [Contribution]] = [:]
    for contribution in contributions {
        byKey[contribution.keyReference, default: []].append(contribution)
    }
    // Sort keys for deterministic diagnostic ordering before flattening.
    return byKey.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
}
