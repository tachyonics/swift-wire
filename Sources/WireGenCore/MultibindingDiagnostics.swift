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
                "@Contributes requires a co-located \(producerList) — without a producer macro Wire can't construct the contributor, so the contribution is silently dropped.",
            severity: .error
        )
    ]
}

/// Every cross-contributor multibinding diagnostic, module-wide:
/// references to undeclared keys, mixed `withOrder:`, and duplicate
/// `atKey:`. Output is sorted by source location for stable build output.
package func multibindingContributionDiagnostics(
    declaredKeyReferences: Set<String>,
    contributions: [Contribution]
) -> [Diagnostic] {
    let diagnostics =
        unknownMultibindingKeyDiagnostics(
            contributions: contributions,
            declaredKeyReferences: declaredKeyReferences
        )
        + mixedContributionOrderingDiagnostics(contributions: contributions)
        + duplicateMapKeyDiagnostics(contributions: contributions)
    return sortedByLocation(diagnostics)
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
/// be a build-time error. Flags the second and later contributions
/// claiming a key already taken.
package func duplicateMapKeyDiagnostics(
    contributions: [Contribution]
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    for (keyReference, group) in groupedByKey(contributions) {
        var firstByMapKey: [String: Contribution] = [:]
        for contribution in group.sorted(by: locationPrecedes) {
            guard let mapKey = contribution.mapKeyExpression else { continue }
            if let first = firstByMapKey[mapKey] {
                diagnostics.append(
                    Diagnostic(
                        location: contribution.location,
                        message:
                            "@Contributes(to: \(keyReference), atKey: \(mapKey)) duplicates the key '\(mapKey)' already contributed at \(first.location.formattedPrefix) — map keys must be unique.",
                        severity: .error
                    )
                )
            } else {
                firstByMapKey[mapKey] = contribution
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

private func locationPrecedes(_ lhs: Contribution, _ rhs: Contribution) -> Bool {
    (lhs.location.file, lhs.location.line, lhs.location.column)
        < (rhs.location.file, rhs.location.line, rhs.location.column)
}

private func sortedByLocation(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
    diagnostics.sorted {
        ($0.location.file, $0.location.line, $0.location.column)
            < ($1.location.file, $1.location.line, $1.location.column)
    }
}
