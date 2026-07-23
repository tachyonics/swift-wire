// MARK: - @Replaces resolution

/// The outcome of resolving `@Replaces` overrides and splitting duplicates: either a
/// pre-resolution validation failure (an invalid `@Replaces`, or a residual duplicate)
/// that aborts graph construction, or the uniquely-bound identities plus the warnings
/// that must still flow to every downstream exit.
package enum ReplacementResolution {
    case earlyExit(GraphResult)
    case resolved(uniqueByIdentity: [BindingIdentity: DiscoveredBinding], warnings: [Diagnostic])
}

/// Resolve `@Replaces` overrides over the identity-grouped bindings, then split the
/// result into uniquely-bound identities vs residual duplicates. An invalid `@Replaces`
/// or a leftover duplicate produces an `.earlyExit` carrying the validation failure;
/// otherwise the uniquely-bound identities and the accumulated warnings are `.resolved`.
/// The warnings (ignored home-package `@Replaces`) thread through every exit.
package func resolveReplacementsAndSplitDuplicates(
    groupedByIdentity: [BindingIdentity: [DiscoveredBinding]],
    genericTemplates: [DiscoveredBinding],
    homeModule: String?,
    externalModules: Set<String>
) -> ReplacementResolution {
    let replacement = resolveReplacements(
        groupedByIdentity,
        homeModule: homeModule,
        externalModules: externalModules
    )
    let replacementWarnings = replacement.warnings
    if !replacement.invalidReplacements.isEmpty {
        return .earlyExit(
            earlyValidationFailure(
                invalidReplacements: replacement.invalidReplacements,
                genericTemplates: genericTemplates,
                warnings: replacementWarnings
            )
        )
    }

    let (uniqueByIdentity, duplicates) = splitUniqueFromDuplicates(replacement.grouped)
    if !duplicates.isEmpty {
        return .earlyExit(
            earlyValidationFailure(
                duplicateBindings: duplicates,
                genericTemplates: genericTemplates,
                warnings: replacementWarnings
            )
        )
    }

    return .resolved(uniqueByIdentity: uniqueByIdentity, warnings: replacementWarnings)
}

/// Apply `@Replaces` overrides to the identity-grouped bindings before
/// duplicate detection. For each slot a binding supersedes, drop the bindings
/// it replaces and keep the replacer alone — so a consumer's `@Replaces`
/// binding wins over a dependency module's binding for the same slot instead
/// of colliding with it.
///
/// Honouring `@Replaces` is a privilege of the composition root's own module.
/// `homeModule` is that module (the consumer target being built), `externalModules`
/// the dependencies pulled from external packages. Three tiers per replacer:
///   - `originModule == homeModule` → **honoured**, then the rules below apply;
///   - a home-package module (non-external, but not the home module) → **ignored
///     with a warning**: the override doesn't fire (a normal duplicate may then
///     surface, or the bindings simply coexist);
///   - an external-package module → **ignored silently**.
/// `homeModule == nil` treats every `@Replaces` as honoured — the behaviour the
/// framework-agnostic unit tests that don't model modules rely on.
///
/// Honoured replacers still obey three rules, surfaced as validation errors:
/// 1. a `@Replaces` with no sibling binding to supersede;
/// 2. two `@Replaces` bindings targeting one slot; and
/// 3. a `@Replaces` superseding a binding from its own module (a plain
///    duplicate the user should resolve directly, not override).
private func resolveReplacements(
    _ groupedByIdentity: [BindingIdentity: [DiscoveredBinding]],
    homeModule: String?,
    externalModules: Set<String>
) -> (
    grouped: [BindingIdentity: [DiscoveredBinding]],
    invalidReplacements: [InvalidReplacement],
    warnings: [Diagnostic]
) {
    // A replacer that actually supersedes: it carries `@Replaces`, and that
    // `@Replaces` is honoured — only from the home module, or from any module when
    // no home module is modelled (the framework-agnostic unit tests that don't).
    func isActiveReplacer(_ binding: DiscoveredBinding) -> Bool {
        guard binding.isReplacer else { return false }
        guard let homeModule else { return true }
        return binding.originModule == homeModule
    }

    var invalid: [InvalidReplacement] = []
    var warnings: [Diagnostic] = []
    let orderedBindings = groupedByIdentity.keys.sorted().flatMap { groupedByIdentity[$0] ?? [] }

    // A `@Replaces` in a home-package module (non-external, but not the home
    // module) can't override — only the composition root's own module may. Warn
    // so the ignored override isn't silently mistaken for taking effect. External
    // modules are ignored silently (no warning).
    if let homeModule {
        for binding in orderedBindings {
            guard binding.isReplacer,
                binding.originModule != homeModule,
                !externalModules.contains(binding.originModule)
            else { continue }
            warnings.append(
                Diagnostic(
                    location: binding.location,
                    message:
                        "@Replaces on '\(binding.identity.displayType)' in module '\(binding.originModule)' has no effect — only the composition root's own module ('\(homeModule)') may override a binding",
                    severity: .warning
                )
            )
        }
    }

    var grouped = groupedByIdentity
    for identity in groupedByIdentity.keys.sorted() {
        let group = groupedByIdentity[identity] ?? []
        let replacers = group.filter(isActiveReplacer)
        guard !replacers.isEmpty else { continue }

        // (2) At most one replacer per slot — two would each claim to win.
        guard replacers.count == 1 else {
            invalid.append(
                InvalidReplacement(
                    reason: .multipleReplacers(key: identity.displayType),
                    replacer: replacers[0],
                    relatedBindings: Array(replacers.dropFirst())
                )
            )
            continue
        }
        let replacer = replacers[0]
        // Everything the replacer supersedes — every binding in the slot that
        // isn't the active replacer itself (including any ignored replacer, which
        // coexists as an ordinary binding).
        let replaced = group.filter { !isActiveReplacer($0) }

        // (1) Nothing to supersede — a `@Replaces` with no sibling for its slot
        // is a mistake or a stale override.
        guard !replaced.isEmpty else {
            invalid.append(
                InvalidReplacement(
                    reason: .nothingToReplace(slot: replacer.identity.displayType),
                    replacer: replacer
                )
            )
            continue
        }

        // (3) Replacing a binding in your own module is just a duplicate you
        // should resolve directly (remove one, or key them apart) — `@Replaces`
        // is for superseding a *dependency*'s binding.
        let sameModule = replaced.filter { $0.originModule == replacer.originModule }
        guard sameModule.isEmpty else {
            invalid.append(
                InvalidReplacement(
                    reason: .sameModule(module: replacer.originModule),
                    replacer: replacer,
                    relatedBindings: sameModule
                )
            )
            continue
        }

        // Valid override: the replacer is the sole binding for the slot.
        grouped[identity] = [replacer]
    }
    return (grouped, invalid, warnings)
}
