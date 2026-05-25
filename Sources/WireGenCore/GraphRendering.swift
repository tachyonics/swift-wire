/// Render the topological order as a numbered human-readable list,
/// suitable for diagnostics and the discovery report. The same order
/// is what code emission iterates over to construct each binding.
package func renderTopologicalOrder(_ order: [DiscoveredBinding]) -> String {
    var lines: [String] = []
    lines.append("topological order (\(order.count) binding(s)):")
    if order.isEmpty {
        lines.append("  (graph is empty)")
    } else {
        for (index, binding) in order.enumerated() {
            lines.append("  \(index + 1). \(displayName(binding))")
        }
    }
    return lines.joined(separator: "\n")
}

/// Render skipped bindings (generic types pending concrete
/// specialisation support) as a short notice, suppressed entirely when
/// none were skipped.
package func renderSkipped(_ skipped: [DiscoveredBinding]) -> String {
    guard !skipped.isEmpty else { return "" }
    var lines: [String] = []
    lines.append("skipped (generic types — concrete specialisation not yet supported):")
    for binding in skipped {
        let generics = "<\(binding.genericParameterNames.joined(separator: ", "))>"
        lines.append("  \(displayName(binding))\(generics)")
    }
    return lines.joined(separator: "\n")
}

/// Render a list of warnings in the Swift-compiler
/// `file:line:col: warning: ...` form, one per line, with optional
/// `note:` lines for related-source pointers. Returns an empty
/// string for an empty input so callers can guard with
/// `.isEmpty` before printing.
package func renderWarnings(_ warnings: [Warning]) -> String {
    var lines: [String] = []
    for warning in warnings {
        lines.append(
            "\(warning.location.formattedPrefix): warning: \(warning.message)"
        )
        for note in warning.notes {
            lines.append(
                "\(note.location.formattedPrefix): note: \(note.message)"
            )
        }
    }
    return lines.joined(separator: "\n")
}

/// Render validation errors in the Swift-compiler `file:line:col: error:`
/// form — one diagnostic per line, no grouping headers. The format is
/// what Xcode and other build-log consumers expect; positions link back
/// to the originating source. Duplicate bindings come first (they
/// short-circuit the rest of validation), then cycles, then missing
/// bindings; within each category, entries are emitted in the order the
/// validator produced them.
package func renderValidationErrors(_ errors: GraphResult.ValidationErrors) -> String {
    var lines: [String] = []

    // Duplicate bindings: one error at the first binding's location,
    // notes at the remaining bindings. When the duplicates are all
    // unkeyed, append a fix-it note pointing at the key-disambiguation
    // pattern. Keyed duplicates already named their key, so the user
    // knows which slot is overloaded — no need to suggest keying.
    for duplicate in errors.duplicateBindings {
        guard let primary = duplicate.bindings.first else { continue }
        let typeSlot = describeTypeSlot(
            boundType: duplicate.boundType,
            key: duplicate.keyIdentifier
        )
        lines.append(
            "\(primary.location.formattedPrefix): error: type \(typeSlot) has multiple bindings; the dependency graph is ambiguous"
        )
        for binding in duplicate.bindings.dropFirst() {
            lines.append(
                "\(binding.location.formattedPrefix): note: also bound here"
            )
        }
        if duplicate.keyIdentifier == nil {
            lines.append(
                "\(primary.location.formattedPrefix): note: to disambiguate, declare named keys (e.g. `static let primary = BindingKey<\(duplicate.boundType)>()`) and tag each binding/consumer with `@Provides(\(duplicate.boundType).primary)` / `@Inject(\(duplicate.boundType).primary)`"
            )
        }
    }

    // Cycles: anchor at the first node in the cycle path. The arrow-
    // separated render reads as "A → B → A" so the user can see the
    // edges at a glance.
    for cycle in errors.cycles {
        guard let anchor = cycle.first else { continue }
        let path = cycle.map { displayName($0) }.joined(separator: " → ")
        lines.append(
            "\(anchor.location.formattedPrefix): error: dependency cycle: \(path)"
        )
    }

    // Missing bindings: anchor at the dependency site (the `@Inject`
    // property/parameter or the `@Provides func` parameter that asked
    // for the type), so the diagnostic lands where the user asked for
    // the missing thing. The consumer's identity is implied by the
    // position — we follow Swift compiler convention and keep the
    // message self-contained rather than restating "(required by 'X')".
    for missing in errors.missingBindings {
        let slot = describeTypeSlot(
            boundType: missing.dependency.type,
            key: missing.dependency.keyIdentifier
        )
        lines.append(
            "\(missing.dependency.location.formattedPrefix): error: no binding produces \(slot)"
        )
        if let hint = missing.typealiasHint {
            lines.append(
                "\(hint.typealiasLocation.formattedPrefix): note: '\(hint.typealiasName)' is a typealias of '\(hint.underlyingType)' which is bound; typealiases aren't unwrapped at resolution, so inject '\(hint.underlyingType)' directly or add a separate binding for '\(hint.typealiasName)'"
            )
        }
        if let hint = missing.crossScopeHint, !hint.matches.isEmpty {
            // Primary note: where the binding lives, contrasted with
            // the consumer's scope. Follows Swift compiler convention
            // for `note:` lines.
            let primary = hint.matches[0]
            lines.append(
                "\(primary.location.formattedPrefix): note: '\(missing.dependency.type)' is bound in \(primary.scopeDescription) scope, not \(hint.consumerScopeDescription)"
            )
            // Additional notes for any other partitions that hold
            // the same binding — the user sees every place the type
            // lives, not just the first sorted match.
            for additional in hint.matches.dropFirst() {
                lines.append(
                    "\(additional.location.formattedPrefix): note: '\(missing.dependency.type)' is also bound in \(additional.scopeDescription) scope"
                )
            }
            // Fix-it: tailored when single match, multiplicity-aware
            // when multiple.
            lines.append(
                "\(missing.dependency.location.formattedPrefix): note: \(hint.fixItSuggestion)"
            )
        }
    }

    // Identifier collisions: primary error at the first colliding
    // binding, notes at the others. The colliding bindings have
    // distinct `(type, key)` identities — what they share is the
    // generated accessor name — so the message names the identifier
    // rather than the type. Fix-it suggestion points at renaming
    // (the keys-disambiguation fix-it doesn't apply: keys are part
    // of the identifier and have already been factored in).
    for collision in errors.identifierCollisions {
        guard let primary = collision.bindings.first else { continue }
        lines.append(
            "\(primary.location.formattedPrefix): error: generated accessor name '\(collision.identifier)' collides across multiple bindings"
        )
        for binding in collision.bindings.dropFirst() {
            lines.append(
                "\(binding.location.formattedPrefix): note: also generates '\(collision.identifier)'"
            )
        }
    }

    return lines.joined(separator: "\n")
}

/// The short identifier to show for a binding in human-facing output:
/// the type name for `@Singleton`, the access path for `@Provides`.
private func displayName(_ binding: DiscoveredBinding) -> String {
    switch binding {
    case .scopeBound(let scopeBound): return scopeBound.typeName
    case .provider(let provider): return provider.accessPath
    }
}

/// Human-facing description of a `(type, key)` slot in the graph. Used
/// in both missing-binding and duplicate-binding diagnostics so the
/// rendering is consistent and keyed slots are clearly named.
///
/// - Unkeyed: `'Database'`
/// - Keyed:   `'Database' keyed 'Database.primary'`
private func describeTypeSlot(boundType: String, key: String?) -> String {
    if let key {
        return "'\(boundType)' keyed '\(key)'"
    }
    return "'\(boundType)'"
}
