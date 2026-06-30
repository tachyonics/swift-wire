// Iteration 5α dead-binding warning: a binding declared but consumed by
// nothing in Wire's visible build. Visibility-gated — `internal`/`package`
// warn (Wire sees all consumers at that scope), `public`/`open` stay
// silent (downstream consumers may exist). `fileprivate`/`private` never
// reach here (the declaration-too-private error already failed the build).
// See `Documentation/Notes/VisibilityModel.md`.
//
// Consumption is judged from both the discovered bindings and the resolved
// graph. A generic binding's dependency reaches a concrete producer only
// after specialisation (a `table: Table` parameter substituted to
// `table: ConcreteTable`); that substituted edge lives in the resolved
// graph's bindings, so feeding those in keeps the concrete producer live.
//
// First-order only: a binding consumed solely by another dead binding is
// not yet detected (no fixed-point pass). Runs per container — each graph
// is atomic, so liveness is judged within the container's own bindings.

/// Dead-binding warnings across a module, grouped by container. Liveness
/// is judged per *container* (all of a container's scopes merged), not per
/// `(container, scope)` partition: a seed scope borrows its container's
/// singletons, so a singleton consumed only by a scope binding must still
/// count as live. Containers are atomic, so each is judged independently.
///
/// `resolvedByContainer` carries each container's resolved-graph bindings
/// (post-specialisation). Their dependency edges count toward liveness on
/// top of the discovered bindings'; a container with no resolved entry
/// falls back to its discovered bindings alone.
///
/// A binding that *carries* an adapter annotation is live: the annotation is an
/// explicit declaration that it's adapted (like a multibinding contributor is
/// live via its aggregate). Only the annotated binding counts — not the
/// adapter's declared dependencies, whose use is the adapter's own opaque logic,
/// so a binding provided solely for an adapter to use stays subject to the
/// normal check. M1 adapters register in the default graph, so these apply to
/// the default (`nil`) container.
package func deadBindingDiagnostics(
    across bindingsByPartition: [Partition: [DiscoveredBinding]],
    resolvedByContainer: [String?: [DiscoveredBinding]] = [:],
    adapterUseSites: [AdapterUseSite] = [],
    adapterDefinitions: [DiscoveredAdapterAnnotation] = []
) -> [Diagnostic] {
    let adapterAnnotated = adapterAnnotatedIdentities(useSites: adapterUseSites, definitions: adapterDefinitions)
    var bindingsByContainer: [String?: [DiscoveredBinding]] = [:]
    for (partition, bindings) in bindingsByPartition {
        bindingsByContainer[partition.container, default: []].append(contentsOf: bindings)
    }
    let diagnostics = bindingsByContainer.flatMap { container, discovered in
        deadBindingDiagnostics(
            in: discovered,
            consumers: discovered + (resolvedByContainer[container] ?? []),
            additionallyConsumed: container == nil ? adapterAnnotated : []
        )
    }
    return diagnostics.sorted { $0.location < $1.location }
}

/// Warn for each binding in `bindings` that no binding consumes, subject to
/// the visibility gate. Consumption is read from the same `bindings`.
package func deadBindingDiagnostics(in bindings: [DiscoveredBinding]) -> [Diagnostic] {
    deadBindingDiagnostics(in: bindings, consumers: bindings)
}

/// Warn for each binding in `bindings` (one container's discovered
/// bindings, no synthesised aggregates) that nothing in `consumers`
/// consumes, subject to the visibility gate. `consumers` is the set whose
/// dependency edges establish liveness — the discovered bindings plus the
/// resolved graph's specialised bindings. Output is sorted by source
/// location for stable build output.
package func deadBindingDiagnostics(
    in bindings: [DiscoveredBinding],
    consumers: [DiscoveredBinding]
) -> [Diagnostic] {
    deadBindingDiagnostics(in: bindings, consumers: consumers, additionallyConsumed: [])
}

/// The implementation, with `additionallyConsumed` — identities consumed by
/// something other than a binding's own dependency edge (an adapter
/// registration). Internal: `BindingIdentity` can't cross the package boundary.
func deadBindingDiagnostics(
    in bindings: [DiscoveredBinding],
    consumers: [DiscoveredBinding],
    additionallyConsumed: Set<BindingIdentity>
) -> [Diagnostic] {
    var producerByIdentity: [BindingIdentity: DiscoveredBinding] = [:]
    for binding in bindings {
        producerByIdentity[binding.identity] = binding
    }
    var consumed = consumedIdentities(in: consumers, producers: producerByIdentity)
    // Adapter-consumed identities resolve through `matchProducer` too, so an
    // optional-promoting or exact match keeps the producer live.
    for identity in additionallyConsumed {
        if case .resolved(let producer) = matchProducer(for: identity, in: producerByIdentity) {
            consumed.insert(producer)
        }
    }

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

/// Identities consumed by any consumer's init-time dependencies or member-
/// injection parameters, resolved through `matchProducer` so optional
/// promotion is honoured (a `T?` dependency keeps the `T` producer live).
private func consumedIdentities(
    in consumers: [DiscoveredBinding],
    producers: [BindingIdentity: DiscoveredBinding]
) -> Set<BindingIdentity> {
    var consumed: Set<BindingIdentity> = []
    func record(_ dependencyIdentity: BindingIdentity) {
        if case .resolved(let producer) = matchProducer(for: dependencyIdentity, in: producers) {
            consumed.insert(producer)
        }
    }
    for binding in consumers {
        for dependency in binding.dependencies {
            record(bridgedDependencyIdentity(dependency, in: binding))
        }
        for injection in binding.memberInjections {
            for parameter in injection.parameters {
                record(bridgedDependencyIdentity(parameter, in: binding))
            }
        }
    }
    return consumed
}

/// Whether an unconsumed binding should warn. An explicit `allowUnused:
/// true` silences it. Generic bindings are skipped — their liveness is via
/// specialisation (consumed as `Foo<Concrete>`), which this first-order
/// analysis doesn't track. A binding that contributes to a multibinding is
/// live via its aggregate's consumer, so it's skipped too (the
/// multibinding empty/dead-key cases handle aggregates separately).
/// `public`/`open` stay silent (external consumers may exist).
private func shouldWarnUnused(_ binding: DiscoveredBinding) -> Bool {
    guard !binding.allowUnused else { return false }
    guard binding.genericParameterNames.isEmpty else { return false }
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
