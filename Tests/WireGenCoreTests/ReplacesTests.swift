import Testing

@testable import WireGenCore

/// `@Replaces` — the binding-override / test-double primitive. A binding
/// carrying `@Replaces(T.self)` supersedes another binding for key `T`
/// (typically one composed in from a dependency module) instead of colliding
/// with it. These exercise the supersede at the graph-construction seam
/// (`resolveReplacements`) and each validation rule it enforces.
@Suite("Replaces")
struct ReplacesTests {
    // MARK: - Helpers

    /// Build a `ReplacesTarget` from a base-type string and optional key, or
    /// `nil` when the base is absent — the shape discovery produces from a
    /// `@Replaces(T.self)` / `@Replaces(T.key)` marker.
    private func target(_ base: String?, key: String? = nil) -> ReplacesTarget? {
        base.map { ReplacesTarget(base: $0, key: key) }
    }

    /// An `@Singleton(as: identity.self)` lift node in `module`, optionally
    /// carrying `@Replaces(replaces.self)`. Mirrors spike-27's shape: both the
    /// real and fake repos bind `some Repo`, so they share graph identity.
    private func opaqueSingleton(
        _ name: String,
        identity: String,
        module: String,
        replaces: String? = nil,
        replacesKey: String? = nil
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                explicitIdentity: identity,
                dependencies: [],
                location: mockLocation("\(name).swift"),
                accessLevel: .package,
                replaces: target(replaces, key: replacesKey),
                originModule: module
            )
        )
    }

    /// A `@Provides let` binding in `module`, optionally keyed.
    private func providerProperty(
        _ accessPath: String,
        boundType: String,
        module: String,
        key: String? = nil
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                keyIdentifier: key,
                accessLevel: .package,
                originModule: module
            )
        )
    }

    /// A `@Provides func` binding in `module`, optionally keyed and/or
    /// `@Replaces`-marked.
    private func providerFunction(
        _ accessPath: String,
        boundType: String,
        module: String,
        key: String? = nil,
        replaces: String? = nil,
        replacesKey: String? = nil
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                keyIdentifier: key,
                accessLevel: .package,
                replaces: target(replaces, key: replacesKey),
                originModule: module
            )
        )
    }

    private func scopeBoundTypeNames(_ order: [DiscoveredBinding]) -> [String] {
        order.compactMap { binding in
            if case .scopeBound(let scopeBound) = binding { return scopeBound.typeName }
            return nil
        }
    }

    // MARK: - Supersede

    @Test func replacesSupersedesSameKeyBindingFromAnotherModule() throws {
        // The motivating case: a test target's fake supersedes an app module's
        // real binding for `some Repo`. The graph resolves to Fake, no error.
        let result = buildDependencyGraph(from: [
            opaqueSingleton("RealRepo", identity: "Repo", module: "AppServer"),
            opaqueSingleton("FakeRepo", identity: "Repo", module: "AppTests", replaces: "Repo"),
        ])
        #expect(result.outcome.validationErrors == nil)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(scopeBoundTypeNames(order) == ["FakeRepo"])
    }

    @Test func providesReplacesSupersedesConcreteSingleton() throws {
        // The `@Provides @Replaces` form, on a concrete (non-opaque) key: the
        // consumer's fake wins over the dependency's real `Client`.
        let result = buildDependencyGraph(from: [
            providerProperty("realClient", boundType: "Client", module: "Lib"),
            providerFunction("fakeClient", boundType: "Client", module: "App", replaces: "Client"),
        ])
        #expect(result.outcome.validationErrors == nil)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.count == 1)
        // Only the replacer (App's fake) survives, proving Fake beat Real.
        #expect(order[0].originModule == "App")
    }

    @Test func plainDuplicateStillErrorsWithoutReplaces() throws {
        // The non-`@Replaces` case is unchanged: two bindings for one key are
        // still a duplicate error, exactly as before.
        let result = buildDependencyGraph(from: [
            opaqueSingleton("RealRepo", identity: "Repo", module: "AppServer"),
            opaqueSingleton("OtherRepo", identity: "Repo", module: "AppTests"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.invalidReplacements.isEmpty)
    }

    // MARK: - Validation (1): produced key must equal the declared target

    @Test func replacesTargetMustMatchProducedKey() throws {
        // Produces `some Repo` but claims to replace `Widget` — you can't claim
        // to replace one type while producing another.
        let result = buildDependencyGraph(from: [
            opaqueSingleton("RealRepo", identity: "Repo", module: "AppServer"),
            opaqueSingleton("FakeRepo", identity: "Repo", module: "AppTests", replaces: "Widget"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.invalidReplacements.count == 1)
        #expect(
            errors.invalidReplacements[0].reason
                == .producedKeyMismatch(declaredTarget: ReplacesTarget(base: "Widget", key: nil), producedType: "some Repo")
        )
        #expect(renderValidationErrors(errors).contains("doesn't match this binding's key"))
    }

    // MARK: - Validation (2): there must be a binding to replace

    @Test func replacesWithNothingToSupersedeDiagnosed() throws {
        // A `@Replaces` whose key no other binding produces is a mistake / stale.
        let result = buildDependencyGraph(from: [
            opaqueSingleton("FakeRepo", identity: "Repo", module: "AppTests", replaces: "Repo")
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.invalidReplacements.count == 1)
        #expect(errors.invalidReplacements[0].reason == .nothingToReplace(declaredTarget: ReplacesTarget(base: "Repo", key: nil)))
        #expect(renderValidationErrors(errors).contains("nothing to supersede"))
    }

    @Test func keyedReplacesMisuseSpellsTheKeyedForm() throws {
        // A keyed `@Replaces(Repo.primary)` that hits a misuse path must render the
        // keyed spelling in the diagnostic, not the `.self` form.
        let result = buildDependencyGraph(
            from: [
                providerFunction(
                    "fakePrimary",
                    boundType: "Repo",
                    module: "App",
                    key: "Repo.primary",
                    replaces: "Repo",
                    replacesKey: "Repo.primary"
                )
            ],
            homeModule: "App"
        )
        let errors = try #require(result.outcome.validationErrors)
        #expect(
            errors.invalidReplacements[0].reason
                == .nothingToReplace(declaredTarget: ReplacesTarget(base: "Repo", key: "Repo.primary"))
        )
        let rendered = renderValidationErrors(errors)
        #expect(rendered.contains("@Replaces(Repo.primary)"))
        #expect(!rendered.contains("@Replaces(Repo.self)"))
    }

    // MARK: - Validation (3): at most one replacer per key

    @Test func twoReplacersForOneKeyDiagnosed() throws {
        let result = buildDependencyGraph(from: [
            opaqueSingleton("RealRepo", identity: "Repo", module: "AppServer"),
            opaqueSingleton("FakeRepo", identity: "Repo", module: "AppTests", replaces: "Repo"),
            opaqueSingleton("OtherFake", identity: "Repo", module: "AppTests", replaces: "Repo"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.invalidReplacements.count == 1)
        #expect(errors.invalidReplacements[0].reason == .multipleReplacers(key: "someRepo"))
        #expect(errors.invalidReplacements[0].relatedBindings.count == 1)
        #expect(renderValidationErrors(errors).contains("more than one @Replaces"))
    }

    // MARK: - Validation (4): the replaced binding must be in another module

    @Test func replacingSameModuleBindingDiagnosed() throws {
        // Overriding your own module's binding is just a duplicate to resolve
        // directly — `@Replaces` is for superseding a dependency's binding.
        let result = buildDependencyGraph(from: [
            opaqueSingleton("RealRepo", identity: "Repo", module: "AppServer"),
            opaqueSingleton("FakeRepo", identity: "Repo", module: "AppServer", replaces: "Repo"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.invalidReplacements.count == 1)
        #expect(errors.invalidReplacements[0].reason == .sameModule(module: "AppServer"))
        #expect(errors.invalidReplacements[0].relatedBindings.count == 1)
        #expect(renderValidationErrors(errors).contains("same module"))
    }

    // MARK: - Full-slot key matching (Refinement 1)

    @Test func keyedReplaceSupersedesSameKeyedBinding() throws {
        // `@Replaces(Repo.primary)` supersedes the `Repo`/`primary` binding from
        // a dependency module — the key is part of the slot the override targets.
        let result = buildDependencyGraph(
            from: [
                providerProperty("realPrimary", boundType: "Repo", module: "Lib", key: "Repo.primary"),
                providerFunction(
                    "fakePrimary",
                    boundType: "Repo",
                    module: "App",
                    key: "Repo.primary",
                    replaces: "Repo",
                    replacesKey: "Repo.primary"
                ),
            ],
            homeModule: "App"
        )
        #expect(result.outcome.validationErrors == nil)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.count == 1)
        #expect(order[0].originModule == "App")
    }

    @Test func unkeyedReplacesDoesNotCrossIntoKeyedSlot() throws {
        // `@Replaces(Repo.self)` targets the UNKEYED `Repo` slot only: it
        // supersedes the unkeyed `RealRepo`, and the keyed `Repo`/`primary`
        // binding survives untouched — a slot the unkeyed override can't reach.
        let result = buildDependencyGraph(
            from: [
                opaqueSingleton("RealRepo", identity: "Repo", module: "Lib"),
                opaqueSingleton("FakeRepo", identity: "Repo", module: "App", replaces: "Repo"),
                providerProperty("realPrimary", boundType: "Repo", module: "Lib", key: "Repo.primary"),
            ],
            homeModule: "App"
        )
        #expect(result.outcome.validationErrors == nil)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(scopeBoundTypeNames(order).sorted() == ["FakeRepo"])
        // The keyed binding is still in the graph — the unkeyed replace left it alone.
        let keyed = order.contains { binding in
            if case .provider(let provider) = binding { return provider.keyIdentifier == "Repo.primary" }
            return false
        }
        #expect(keyed)
    }

    @Test func replacesSelfOnKeyedProducerIsSlotMismatch() throws {
        // Refinement 1's bug fix: a binding that PRODUCES `Repo`/`primary` but
        // declares `@Replaces(Repo.self)` names a slot it isn't in — the key is
        // part of the identity, so this is a produced-key mismatch, not a match.
        let result = buildDependencyGraph(
            from: [
                providerFunction(
                    "fake",
                    boundType: "Repo",
                    module: "App",
                    key: "Repo.primary",
                    replaces: "Repo"
                )
            ],
            homeModule: "App"
        )
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.invalidReplacements.count == 1)
        #expect(
            errors.invalidReplacements[0].reason
                == .producedKeyMismatch(declaredTarget: ReplacesTarget(base: "Repo", key: nil), producedType: "Repo")
        )
    }

    // MARK: - Home-module privilege (Refinement 2)

    @Test func homeModuleReplacesIsHonoured() throws {
        // The composition root's own module may override — the home `@Replaces`
        // supersedes the dependency module's binding, no error, no warning.
        let result = buildDependencyGraph(
            from: [
                opaqueSingleton("RealRepo", identity: "Repo", module: "Lib"),
                opaqueSingleton("FakeRepo", identity: "Repo", module: "App", replaces: "Repo"),
            ],
            homeModule: "App"
        )
        #expect(result.outcome.validationErrors == nil)
        #expect(result.warnings.isEmpty)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(scopeBoundTypeNames(order) == ["FakeRepo"])
    }

    @Test func homePackageReplacesIgnoredWithWarning() throws {
        // A `@Replaces` in a home-package module that ISN'T the composition root
        // has no effect: it doesn't supersede (so the plain duplicate surfaces),
        // and a warning explains why.
        let result = buildDependencyGraph(
            from: [
                opaqueSingleton("RealRepo", identity: "Repo", module: "AppServer"),
                opaqueSingleton("FakeRepo", identity: "Repo", module: "HelperLib", replaces: "Repo"),
            ],
            homeModule: "App"
        )
        let errors = try #require(result.outcome.validationErrors)
        // The override was ignored, so the two bindings collide as an ordinary duplicate.
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.invalidReplacements.isEmpty)
        // A single warning, at warning severity, naming the offending module and the home module.
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].severity == .warning)
        #expect(result.warnings[0].message.contains("has no effect"))
        #expect(result.warnings[0].message.contains("HelperLib"))
        #expect(result.warnings[0].message.contains("App"))
    }

    @Test func externalModuleReplacesIgnoredSilently() throws {
        // A `@Replaces` from an external-package module is ignored with no
        // warning — the override simply doesn't fire, so the duplicate surfaces.
        let result = buildDependencyGraph(
            from: [
                opaqueSingleton("RealRepo", identity: "Repo", module: "App"),
                opaqueSingleton("FakeRepo", identity: "Repo", module: "ExternalPkg", replaces: "Repo"),
            ],
            homeModule: "App",
            externalModules: ["ExternalPkg"]
        )
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.invalidReplacements.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func nilHomeModuleHonoursEveryReplaces() throws {
        // With no home module supplied (the module-agnostic default), every
        // `@Replaces` is honoured — the behaviour the plain unit tests rely on.
        let result = buildDependencyGraph(from: [
            opaqueSingleton("RealRepo", identity: "Repo", module: "Lib"),
            opaqueSingleton("FakeRepo", identity: "Repo", module: "AnyOther", replaces: "Repo"),
        ])
        #expect(result.outcome.validationErrors == nil)
        #expect(result.warnings.isEmpty)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(scopeBoundTypeNames(order) == ["FakeRepo"])
    }
}
