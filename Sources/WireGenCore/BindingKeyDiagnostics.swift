// Missing-key diagnostic for single-binding keys — the behavioural half
// of iteration 7a. Now that Wire tracks `BindingKey` declarations
// (`BindingKeyScanning`), a `@Inject(K)` / `@Provides(K)` reference whose
// `K` matches no declared key is an error, exactly as `@Contributes(to: X)`
// against an unknown multibinding key already is. The valid set is the
// *union* of single `BindingKey`s and multibinding keys, since an
// aggregate consumer (`@Inject(App.services)`) references a multibinding
// key the same way. The check is scoped to the parse set (one module
// today; it widens automatically under composition — see
// `MultiModuleComposition.md`).

/// Every `@Inject(K)` / `@Provides(K)` reference (binding-level keys and
/// dependency keys, across all partitions) whose `K` matches no declared
/// key — neither a single `BindingKey` nor a multibinding key. Each
/// offending site gets an error anchored at the reference.
///
/// Aggregate bindings are skipped: they're synthesised, and their key is
/// the declared multibinding key the fan-in pass built them from.
package func unknownBindingKeyDiagnostics(
    bindingsByPartition: [Partition: [DiscoveredBinding]],
    declaredKeyReferences: Set<String>
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []

    func check(_ keyIdentifier: String?, at location: SourceLocation) {
        guard let key = keyIdentifier, !declaredKeyReferences.contains(key) else { return }
        diagnostics.append(
            Diagnostic(
                location: location,
                message:
                    "key '\(key)' is referenced but never declared — declare a 'static let \(key) = BindingKey<T>()' (or a CollectedKey/MappedKey/BuilderKey for a multibinding) in the parse set, or fix the reference.",
                severity: .error
            )
        )
    }

    for bindings in bindingsByPartition.values {
        for binding in bindings {
            switch binding {
            case .provider(let provider):
                check(provider.keyIdentifier, at: provider.location)
                for dependency in provider.dependencies {
                    check(dependency.keyIdentifier, at: dependency.location)
                }
            case .scopeBound(let scopeBound):
                for dependency in scopeBound.dependencies {
                    check(dependency.keyIdentifier, at: dependency.location)
                }
                for memberInjection in scopeBound.memberInjections {
                    for parameter in memberInjection.parameters {
                        check(parameter.keyIdentifier, at: parameter.location)
                    }
                }
            case .aggregate:
                break
            }
        }
    }
    return diagnostics.sorted { $0.location < $1.location }
}
