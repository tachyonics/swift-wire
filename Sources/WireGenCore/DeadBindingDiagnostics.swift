// Iteration 5α dead-binding warning: a binding declared but consumed by
// nothing in Wire's visible build. Visibility-gated — `internal`/`package`
// warn (Wire sees all consumers at that scope), `public`/`open` stay
// silent (downstream consumers may exist). `fileprivate`/`private` never
// reach here (the declaration-too-private error already failed the build).
// See `Documentation/Notes/VisibilityModel.md`.
//
// First-order only: a binding consumed solely by another dead binding is
// not yet detected (no fixed-point pass). Runs per partition — each graph
// is atomic, so liveness is judged within the partition's own bindings.

/// Warn for each binding in `bindings` that no other binding consumes,
/// subject to the visibility gate. `bindings` is one partition's
/// discovered bindings (no synthesised aggregates). Output is sorted by
/// source location for stable build output.
package func deadBindingDiagnostics(in bindings: [DiscoveredBinding]) -> [Diagnostic] {
    var producerByIdentity: [BindingIdentity: DiscoveredBinding] = [:]
    for binding in bindings {
        producerByIdentity[binding.identity] = binding
    }
    let consumed = consumedIdentities(in: bindings, producers: producerByIdentity)

    var diagnostics: [Diagnostic] = []
    for identity in producerByIdentity.keys.sorted() where !consumed.contains(identity) {
        guard let binding = producerByIdentity[identity], shouldWarnUnused(binding) else { continue }
        diagnostics.append(
            Diagnostic(
                location: binding.location,
                message:
                    "\(describeSlot(binding)) is declared but nothing in the build consumes it. Inject it somewhere, raise it to 'public' if it's consumed outside this \(binding.accessLevel == .package ? "package" : "target"), or mark it 'allowUnused: true' to silence.",
                severity: .warning
            )
        )
    }
    return diagnostics.sorted { $0.location < $1.location }
}

/// Identities consumed by any binding's init-time dependencies or member-
/// injection parameters, resolved through `matchProducer` so optional
/// promotion is honoured (a `T?` dependency keeps the `T` producer live).
private func consumedIdentities(
    in bindings: [DiscoveredBinding],
    producers: [BindingIdentity: DiscoveredBinding]
) -> Set<BindingIdentity> {
    var consumed: Set<BindingIdentity> = []
    func record(_ dependencyIdentity: BindingIdentity) {
        if case .resolved(let producer) = matchProducer(for: dependencyIdentity, in: producers) {
            consumed.insert(producer)
        }
    }
    for binding in bindings {
        for dependency in binding.dependencies {
            record(dependency.identity)
        }
        for injection in binding.memberInjections {
            for parameter in injection.parameters {
                record(parameter.identity)
            }
        }
    }
    return consumed
}

/// Whether an unconsumed binding should warn. An explicit `allowUnused:
/// true` silences it. `public`/`open` stay silent (external consumers may
/// exist). A binding that contributes to a multibinding is live via its
/// aggregate's consumer, so it's skipped here (the multibinding empty/
/// dead-key cases handle aggregates separately).
private func shouldWarnUnused(_ binding: DiscoveredBinding) -> Bool {
    guard !binding.allowUnused else { return false }
    guard binding.contributions.isEmpty else { return false }
    switch binding.accessLevel {
    case .internal, .package: return true
    case .public, .open, .fileprivate, .private: return false
    }
}

/// Human-facing identifier for the dead binding — the bound type, with a
/// keyed slot rendered as `T (key)` so two same-type bindings are
/// distinguishable.
private func describeSlot(_ binding: DiscoveredBinding) -> String {
    if let key = binding.keyIdentifier {
        return "'\(binding.boundType)' (key \(key))"
    }
    return "'\(binding.boundType)'"
}
