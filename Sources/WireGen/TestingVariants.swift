import Foundation
import WireGenCore

/// Test-graph variant construction — the executable half of the M6a Phase 1 primitives. Each
/// `TestingKey` selects a graph variant: its `@BindType` substitutions rewrite the named slots into
/// doubles-sourced bindings, and the variant is emitted alongside the production graphs as a
/// container-shaped `_<KeyRef>WireGraph` + its seed scopes (threaded with the variant's `_<Key>Doubles`)
/// + the doubles struct. The production graph is untouched — a module with no `TestingKey` emits exactly
/// what it did before.
extension WireGen {
    /// One test-graph variant ready for emission: its `_<Key>Doubles` struct declaration, the
    /// doubles-threaded variant seed scopes, the rule-3 promotions across them, any scope that failed
    /// validation (surfaced then aborted on), and the source-pattern diagnostics the variant raised (the
    /// cascade's unmarked-`@Scopable` hops and stale-`@BindType` substitutions).
    struct TestingVariant {
        let doublesStruct: String
        let seedScopes: [SeedScopeEmission]
        let existentialPromotions: [ExistentialPromotion]
        let validationFailures: [(name: String, errors: GraphResult.ValidationErrors)]
        let diagnostics: [Diagnostic]
    }

    /// The production-graph inputs the per-partition accumulation reuses across a testing key's seed
    /// partitions: the default-graph seed partitions to vary, the app singletons the cascade may lift, the
    /// production app graph's resolved adjacency the cascade walks, and the singleton borrow set the
    /// variant scopes reuse.
    fileprivate struct VariantPartitionInputs {
        let seedPartitions: [(key: Partition, value: [DiscoveredBinding])]
        let defaultSingletons: [DiscoveredBinding]
        let appEdges: [BindingIdentity: [BindingIdentity]]
        let borrows: [DiscoveredBinding]
    }

    /// One testing key's variant seed scopes accumulated across the default-graph seed partitions: the
    /// doubles fields collected per scope, the built variant seed scopes, their existential promotions,
    /// the scopes that failed validation, and the cascade diagnostics raised.
    fileprivate struct VariantScopeAccumulation {
        var doublesFields: [String: DoublesField] = [:]
        var seedScopes: [SeedScopeEmission] = []
        var promotions: [ExistentialPromotion] = []
        var failures: [(name: String, errors: GraphResult.ValidationErrors)] = []
        var diagnostics: [Diagnostic] = []
    }

    /// Build a variant per discovered `TestingKey` (deduped by reference). The variant reuses the production
    /// `_WireGraph` as its parent — the app graph is unchanged — and diverges only in its seed scopes:
    ///
    /// - **Phase 1 (no cascade):** a `@BindType` substitutes a binding *already inside a seed scope*, which
    ///   is rewritten so the slot resolves to `doubles.<field>`.
    /// - **Phase 2 (the `@Scopable` cascade):** a `@BindType`d binding reached through *app-scoped*
    ///   consumers. `cascadeLift` walks from it up to the seed roots; every app singleton on the path (the
    ///   mocked leaf plus each `@Scopable`d hop) is *lifted* out of the borrow set and into the scope's own
    ///   binding set, so it's reconstructed per scope entry and a `@Singleton` consumer sees the double —
    ///   including at its `init`. An unmarked hop raises a guided diagnostic instead.
    ///
    /// The affected scopes are disambiguated from production by the key (`_<KeyRef>_<Seed>WireScope`) and
    /// thread the variant's `_<Key>Doubles` alongside the seed. `appEdges` is the production app graph's
    /// resolved adjacency, which the cascade walks.
    static func buildTestingVariants(
        in aggregate: DiscoveryAggregate,
        appEdges: [BindingIdentity: [BindingIdentity]]
    ) -> [TestingVariant] {
        // Production default-graph singletons and the borrow set the variant scopes reuse — the variant
        // borrows the production `_WireGraph` for every app singleton it does not lift.
        let defaultSingletons =
            aggregate.allBindings
            .filter { $0.key.container == nil && $0.key.scope == nil }
            .flatMap { $0.value }
        let borrows = syntheticSingletonBorrowBindings(from: defaultSingletons, inWireGraphOfType: "_WireGraph")
        // Default-graph seed partitions, deterministically ordered by seed.
        let seedPartitions =
            aggregate.allBindings
            .filter { $0.key.container == nil && $0.key.scope != nil }
            .sorted { ($0.key.scope?.seed ?? "") < ($1.key.scope?.seed ?? "") }
        let allProductionBindings = defaultSingletons + seedPartitions.flatMap { $0.value }
        let partitionInputs = VariantPartitionInputs(
            seedPartitions: seedPartitions,
            defaultSingletons: defaultSingletons,
            appEdges: appEdges,
            borrows: borrows
        )

        var variants: [TestingVariant] = []
        var seen: Set<String> = []
        for key in aggregate.testingKeys {
            guard seen.insert(key.keyReference).inserted else { continue }
            let variantName = key.keyReference.split(separator: ".").map(String.init).joined(separator: "_")
            let doublesType = doublesStructTypeName(forKeyReference: key.keyReference)
            let scopeContext = VariantScopeContext(
                keyReference: key.keyReference,
                variantName: variantName,
                doublesType: doublesType,
                aggregate: aggregate
            )

            let accumulation = accumulateVariantScopes(key: key, partitions: partitionInputs, context: scopeContext)

            // A `@BindType` whose slot no production binding produces is stale — surfaced, not discarded.
            var diagnostics = accumulation.diagnostics
            diagnostics += unmatchedSubstitutions(key.substitutions, against: allProductionBindings)
                .map(unmatchedBindTypeDiagnostic)

            guard !accumulation.doublesFields.isEmpty || !accumulation.failures.isEmpty || !diagnostics.isEmpty
            else { continue }
            variants.append(
                TestingVariant(
                    doublesStruct: renderDoublesStruct(
                        typeName: doublesType,
                        fields: accumulation.doublesFields.values.sorted { $0.name < $1.name }
                    ),
                    seedScopes: accumulation.seedScopes,
                    existentialPromotions: accumulation.promotions,
                    validationFailures: accumulation.failures,
                    diagnostics: diagnostics
                )
            )
        }
        return variants
    }

    /// Accumulate one testing key's variant seed scopes across the default-graph seed partitions. Per
    /// partition it applies the Phase-1 `@BindType` substitutions (a slot already inside the seed scope)
    /// and the Phase-2 `@Scopable` cascade (app singletons lifted into the scope), then orchestrates the
    /// substituted + lifted scope — folding the doubles fields, built scopes, existential promotions,
    /// validation failures, and cascade diagnostics into one accumulation.
    fileprivate static func accumulateVariantScopes(
        key: DiscoveredTestingKey,
        partitions: VariantPartitionInputs,
        context: VariantScopeContext
    ) -> VariantScopeAccumulation {
        let scopableTypeNames = Set(key.scopables.map(\.typeName))
        var accumulation = VariantScopeAccumulation()

        for (partition, bindings) in partitions.seedPartitions {
            guard let seedKey = partition.scope else { continue }

            // Phase 1 — substitutions that hit a binding already in this seed scope.
            let seedSubstituted = applyBindTypeSubstitutions(to: bindings, substitutions: key.substitutions)

            // Phase 2 — the cascade: the app singletons (mocked leaf + `@Scopable`d hops) to lift in.
            let cascade = cascadeLift(
                seedBindings: bindings,
                appSingletons: partitions.defaultSingletons,
                appEdges: partitions.appEdges,
                substitutions: key.substitutions,
                scopableTypeNames: scopableTypeNames
            )
            accumulation.diagnostics += cascade.unmarkedHops.map(unmarkedCascadeHopDiagnostic)
            let liftedBindings = partitions.defaultSingletons.filter { cascade.liftedIdentities.contains($0.identity) }
            let liftedSubstituted = applyBindTypeSubstitutions(
                to: liftedBindings,
                substitutions: key.substitutions
            )

            // A scope neither directly substituted nor reached by a lift needs no variant.
            let scopeDoublesFields = seedSubstituted.doublesFields + liftedSubstituted.doublesFields
            guard !scopeDoublesFields.isEmpty else { continue }
            for field in scopeDoublesFields { accumulation.doublesFields[field.name] = field }

            // The lifted app singletons construct *in the scope* — so they leave the borrow set (else a
            // borrow and a scope-bound binding would collide on one identity).
            let scopeBorrows = partitions.borrows.filter { !cascade.liftedIdentities.contains($0.identity) }

            switch orchestrateVariantScope(
                seedKey: seedKey,
                scopeBindings: seedSubstituted.bindings + liftedSubstituted.bindings,
                scopeBorrows: scopeBorrows,
                context: context
            ) {
            case .failed(let name, let errors):
                accumulation.failures.append((name: name, errors: errors))
            case .built(let seedScope, let scopePromotions):
                accumulation.promotions += scopePromotions
                accumulation.seedScopes.append(seedScope)
            }
        }
        return accumulation
    }

    /// Write any test-graph variant's source-pattern diagnostics (the cascade's unmarked-`@Scopable` hops
    /// and stale-`@BindType` substitutions) and validation failures to stderr, and `exit(1)` on any error —
    /// same discipline as the production graphs, so a broken variant fails the build with a guided message
    /// rather than emitting code that won't compile.
    static func failIfAnyTestingVariantInvalid(_ variants: [TestingVariant]) {
        let diagnostics = variants.flatMap { $0.diagnostics }
        printDiagnostics(diagnostics)

        let failures = variants.flatMap { $0.validationFailures }
        for failure in failures {
            FileHandle.standardError.write(Data("\nin \(failure.name):\n".utf8))
            FileHandle.standardError.write(Data(renderValidationErrors(failure.errors).utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }

        let hasError = diagnostics.contains { $0.severity == .error } || !failures.isEmpty
        if hasError { exit(1) }
    }
}

extension WireGen {
    /// The inputs `orchestrateVariantScope` needs beyond the per-partition bindings — constant across a
    /// testing key's seed partitions.
    fileprivate struct VariantScopeContext {
        let keyReference: String
        let variantName: String
        let doublesType: String
        let aggregate: DiscoveryAggregate
    }

    /// The outcome of orchestrating one variant seed scope: a validation failure to collect, or the built
    /// scope emission with its existential promotions.
    fileprivate enum VariantScopeOutcome {
        case failed(name: String, errors: GraphResult.ValidationErrors)
        case built(SeedScopeEmission, [ExistentialPromotion])
    }

    /// Orchestrate one testing-variant seed scope — run its substituted + lifted bindings through
    /// `orchestrateSeedScope` against the reused production `_WireGraph`, and package the result.
    fileprivate static func orchestrateVariantScope(
        seedKey: ScopeKey,
        scopeBindings: [DiscoveredBinding],
        scopeBorrows: [DiscoveredBinding],
        context: VariantScopeContext
    ) -> VariantScopeOutcome {
        let orchestration = orchestrateSeedScope(
            seedKey: seedKey,
            containerName: context.variantName,  // disambiguates the emitted names; the parent stays `_WireGraph`
            scopeBindings: scopeBindings,
            borrowBindings: scopeBorrows,
            parentGraphType: "_WireGraph",
            typealiases: context.aggregate.typealiases,
            multibindingKeys: context.aggregate.multibindingKeys,
            resultBuilders: context.aggregate.resultBuilders,
            module: context.aggregate.module,
            homeModule: context.aggregate.module,
            externalModules: context.aggregate.externalModules
        )
        guard let order = orchestration.result.outcome.topologicalOrder else {
            let errors =
                orchestration.result.outcome.validationErrors
                ?? GraphResult.ValidationErrors(cycles: [], missingBindings: [], duplicateBindings: [])
            return .failed(
                name: "testing variant '\(context.keyReference)' scope '\(seedKey.seed)'",
                errors: errors
            )
        }
        return .built(
            SeedScopeEmission(
                seedTypeExpression: orchestration.seedTypeExpression,
                identifierSuffix: orchestration.identifierSuffix,
                parentGraphType: orchestration.parentGraphType,
                topologicalOrder: order,
                borrowedBindingPropertyNames: orchestration.borrowedBindingPropertyNames,
                edges: orchestration.result.edges,
                existentialPromotions: orchestration.result.existentialPromotions,
                doublesType: context.doublesType
            ),
            orchestration.result.existentialPromotions
        )
    }
}
