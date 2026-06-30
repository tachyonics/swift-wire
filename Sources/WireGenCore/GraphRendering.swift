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

/// Render the generic templates that aren't constructed directly as a
/// short notice, suppressed entirely when there are none. Wire builds a
/// concrete binding for each instantiation a consumer requests; those
/// instantiations appear in the topological order. A template no consumer
/// instantiates contributes nothing to the graph.
package func renderGenericTemplates(_ genericTemplates: [DiscoveredBinding]) -> String {
    guard !genericTemplates.isEmpty else { return "" }
    var lines: [String] = []
    lines.append("generic templates (not constructed directly; specialised per requested instantiation):")
    for binding in genericTemplates {
        let generics = "<\(binding.genericParameterNames.joined(separator: ", "))>"
        lines.append("  \(displayName(binding))\(generics)")
    }
    return lines.joined(separator: "\n")
}

/// Render a list of diagnostics in the Swift-compiler
/// `file:line:col: <severity>: ...` form, one per line, with
/// optional `note:` lines for related-source pointers. The
/// severity prefix is `"warning"` or `"error"` based on the
/// diagnostic's `severity` field. Returns an empty string for an
/// empty input so callers can guard with `.isEmpty` before
/// printing.
package func renderDiagnostics(_ diagnostics: [Diagnostic]) -> String {
    var lines: [String] = []
    for diagnostic in diagnostics {
        let severityLabel: String
        switch diagnostic.severity {
        case .warning: severityLabel = "warning"
        case .error: severityLabel = "error"
        }
        lines.append(
            "\(diagnostic.location.formattedPrefix): \(severityLabel): \(diagnostic.message)"
        )
        for note in diagnostic.notes {
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
    for duplicate in errors.duplicateBindings {
        lines.append(contentsOf: duplicateBindingLines(duplicate))
    }
    for cycle in errors.cycles {
        lines.append(contentsOf: cycleLines(cycle))
    }
    for missing in errors.missingBindings {
        lines.append(contentsOf: missingBindingLines(missing))
    }
    for collision in errors.identifierCollisions {
        lines.append(contentsOf: collisionLines(collision))
    }
    return lines.joined(separator: "\n")
}

/// Render one duplicate-binding error: the primary error, "also bound
/// here" notes at the remaining bindings, and — when the duplicates are
/// all unkeyed — a fix-it pointing at the key-disambiguation pattern.
/// (Keyed duplicates already named their slot, so no keying suggestion.)
private func duplicateBindingLines(_ duplicate: DuplicateBinding) -> [String] {
    guard let primary = duplicate.bindings.first else { return [] }
    let typeSlot = describeTypeSlot(boundType: duplicate.boundType, key: duplicate.keyIdentifier)
    // When the conflicting bindings come from different modules, name the
    // module on each — a cross-library ambiguity (two activated libraries
    // binding the same type) is otherwise hard to place. Same-module
    // duplicates keep the original wording (the suffix is empty).
    let crossModule = Set(duplicate.bindings.map(\.originModule)).count > 1
    func moduleSuffix(_ binding: DiscoveredBinding) -> String {
        crossModule ? " (module '\(binding.originModule)')" : ""
    }
    var lines = [
        "\(primary.location.formattedPrefix): error: type \(typeSlot) has multiple bindings; the dependency graph is ambiguous\(moduleSuffix(primary))"
    ]
    for binding in duplicate.bindings.dropFirst() {
        lines.append("\(binding.location.formattedPrefix): note: also bound here\(moduleSuffix(binding))")
    }
    if duplicate.keyIdentifier == nil {
        lines.append(
            "\(primary.location.formattedPrefix): note: to disambiguate, declare named keys (e.g. `static let primary = BindingKey<\(duplicate.boundType)>()`) and tag each binding/consumer with `@Provides(\(duplicate.boundType).primary)` / `@Inject(\(duplicate.boundType).primary)`"
        )
    }
    return lines
}

/// Render one dependency cycle, anchored at the first node, as an
/// arrow-separated path ("A → B → A"), plus a note for any
/// `@Inject weak let` edge that closes it (converting to `weak var`
/// breaks the cycle by delivering it post-construct).
private func cycleLines(_ cycle: [DiscoveredBinding]) -> [String] {
    guard let anchor = cycle.first else { return [] }
    let path = cycle.map { displayName($0) }.joined(separator: " → ")
    var lines = ["\(anchor.location.formattedPrefix): error: dependency cycle: \(path)"]
    lines.append(contentsOf: nonOwningEdgeBreakNotes(in: cycle))
    return lines
}

/// For each consecutive edge `X → Y` in the cycle path, a *non-owning*
/// init-time edge on `X` that resolves to `Y` (`@Inject weak let` /
/// `unowned`) is one `weak var` would break (post-construct delivery).
/// Point the user at each one.
private func nonOwningEdgeBreakNotes(in cycle: [DiscoveredBinding]) -> [String] {
    var notes: [String] = []
    for (consumer, producer) in zip(cycle, cycle.dropFirst()) {
        let producerSet = [producer.identity: producer]
        for dep in consumer.dependencies {
            guard let form = dep.nonOwningInitForm else { continue }
            guard case .resolved = matchProducer(
                for: bridgedDependencyIdentity(dep, in: consumer),
                in: producerSet
            ) else { continue }
            notes.append(
                "\(dep.location.formattedPrefix): note: '\(dep.name ?? dep.type)' is an '@Inject \(form.description)' that closes this cycle; change it to 'weak var' to break the cycle (the bootstrap then delivers it post-construct, off the init-time edge)"
            )
        }
    }
    return notes
}

/// Render one generated-accessor-name collision: primary error at the
/// first binding, "also generates 'X'" notes at the rest. The colliding
/// bindings have distinct `(type, key)` identities — they share only the
/// generated accessor name — so the message names the identifier.
private func collisionLines(_ collision: IdentifierCollision) -> [String] {
    guard let primary = collision.bindings.first else { return [] }
    var lines = [
        "\(primary.location.formattedPrefix): error: generated accessor name '\(collision.identifier)' collides across multiple bindings"
    ]
    for binding in collision.bindings.dropFirst() {
        lines.append("\(binding.location.formattedPrefix): note: also generates '\(collision.identifier)'")
    }
    return lines
}

/// Render one missing binding: the primary `error:` line anchored at the
/// dependency site, plus any `note:` hints (typealias, cross-scope, or
/// optional mismatch). Anchoring at the dependency site lands the user
/// on the line that asked for the missing thing; the consumer's identity
/// is implied by position (Swift compiler convention).
private func missingBindingLines(_ missing: MissingBinding) -> [String] {
    var lines: [String] = []
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
        // Primary note: where the binding lives, contrasted with the
        // consumer's scope. Follows Swift compiler convention.
        let primary = hint.matches[0]
        lines.append(
            "\(primary.location.formattedPrefix): note: '\(missing.dependency.type)' is bound in \(primary.scopeDescription) scope, not \(hint.consumerScopeDescription)"
        )
        // Additional notes for any other partitions that hold the same
        // binding — the user sees every place the type lives.
        for additional in hint.matches.dropFirst() {
            lines.append(
                "\(additional.location.formattedPrefix): note: '\(missing.dependency.type)' is also bound in \(additional.scopeDescription) scope"
            )
        }
        lines.append(
            "\(missing.dependency.location.formattedPrefix): note: \(hint.fixItSuggestion)"
        )
    }
    if let hint = missing.optionalMismatchHint {
        let base = optionalityStripped(missing.dependency.type).base
        switch hint {
        case .optionalProducerCannotSatisfyNonOptional:
            lines.append(
                "\(missing.dependency.location.formattedPrefix): note: a '\(base)?' producer exists but can't satisfy non-optional '\(base)' (a '\(base)?' may be nil) — change the consumer to '\(base)?', or have the producer return '\(base)'"
            )
        case .optionalNeedsExplicitProducer:
            lines.append(
                "\(missing.dependency.location.formattedPrefix): note: Wire never injects nil for an absent binding; an optional dependency still needs an explicit producer (return '\(base)', or '\(base)?' if it may be nil)"
            )
        }
    }
    return lines
}

/// The short identifier to show for a binding in human-facing output:
/// the type name for `@Singleton`, the access path for `@Provides`.
private func displayName(_ binding: DiscoveredBinding) -> String {
    switch binding {
    case .scopeBound(let scopeBound): return scopeBound.typeName
    case .provider(let provider): return provider.accessPath
    case .aggregate(let aggregate): return aggregate.collectionType
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
