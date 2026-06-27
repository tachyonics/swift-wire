import Testing

@testable import WireGenCore

@Suite("Discovery")
struct DiscoveryTests {
    /// Extract just the `@Singleton` bindings — preserves the
    /// pre-`@Provides` shape of these tests, which assert on
    /// `DiscoveredScopeBoundType` fields directly.
    private func discoverSingletons(
        in source: String,
        sourcePath: String
    ) -> [DiscoveredScopeBoundType] {
        discover(in: source, sourcePath: sourcePath, module: testModule).bindings.compactMap { binding in
            if case .scopeBound(let scopeBound) = binding { return scopeBound }
            return nil
        }
    }

    /// Extract just the `@Provides` bindings.
    private func discoverProviders(
        in source: String,
        sourcePath: String
    ) -> [DiscoveredProvider] {
        discover(in: source, sourcePath: sourcePath, module: testModule).bindings.compactMap { binding in
            if case .provider(let provider) = binding { return provider }
            return nil
        }
    }

    /// Extract the `@Provides` bindings in a specific partition — scoped
    /// providers route out of the default `.bindings` slice into their
    /// `(container, seed)` cell.
    private func discoverProviders(
        in source: String,
        sourcePath: String,
        partition: Partition
    ) -> [DiscoveredProvider] {
        (discover(in: source, sourcePath: sourcePath, module: testModule).allBindings[partition] ?? [])
            .compactMap { binding in
                if case .provider(let provider) = binding { return provider }
                return nil
            }
    }

    @Test func emptySourceFindsNoSingletons() {
        let result = discoverSingletons(in: "", sourcePath: "Empty.swift")
        #expect(result.isEmpty)
    }

    @Test func sourceWithoutAnyAnnotationsFindsNoSingletons() {
        let source = """
            struct Plain {
                var x: Int
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Plain.swift")
        #expect(result.isEmpty)
    }

    @Test func singletonOnStructIsDiscovered() {
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "A")
        #expect(result[0].typeKind == "struct")
        #expect(result[0].sourcePath == "A.swift")
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == "b")
        #expect(result[0].dependencies[0].type == "B")
        #expect(result[0].dependencies[0].kind == .injectProperty)
    }

    @Test func singletonOnClassIsDiscovered() {
        let source = """
            @Singleton
            final class A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].typeKind == "class")
    }

    @Test func singletonOnActorIsDiscovered() {
        let source = """
            @Singleton
            actor A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].typeKind == "actor")
    }

    @Test func singletonWithNoInjectsHasEmptyDependencies() {
        let source = """
            @Singleton
            struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
    }

    @Test func singletonGenericParametersCaptured() {
        let source = """
            @Singleton
            struct Repository<Model> {
                @Inject var store: Store
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Repository.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "Repository")
        #expect(result[0].genericParameterNames == ["Model"])
    }

    @Test func singletonMultipleGenericParametersCaptured() {
        let source = """
            @Singleton
            struct Pair<Left, Right> {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Pair.swift")
        #expect(result.count == 1)
        #expect(result[0].genericParameterNames == ["Left", "Right"])
    }

    @Test func injectInitParametersTakePrecedenceOverProperties() {
        // When a type has both @Inject properties and an @Inject init, the
        // init's parameter list wins. (The macro flags this combination as
        // an error during compilation; WireGen is downstream of that and
        // takes a best-effort posture.)
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
                @Inject
                init(c: C) {
                    self.b = B(c: c)
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == "c")
        #expect(result[0].dependencies[0].type == "C")
        #expect(result[0].dependencies[0].kind == .injectInitParameter)
    }

    @Test func injectInitWithMultipleParametersPreservesOrder() {
        let source = """
            @Singleton
            struct A {
                @Inject
                init(first: First, second: Second, third: Third) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result[0].dependencies.map { $0.name } == ["first", "second", "third"])
        #expect(result[0].dependencies.map { $0.type } == ["First", "Second", "Third"])
    }

    @Test func multipleInjectPropertiesInOrder() {
        let source = """
            @Singleton
            struct A {
                @Inject var first: First
                @Inject var second: Second
                @Inject var third: Third
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result[0].dependencies.map { $0.name } == ["first", "second", "third"])
    }

    @Test func unannotatedTypeIsIgnored() {
        let source = """
            struct A {
                @Inject var b: B
            }

            @Singleton
            struct B {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Mixed.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "B")
    }

    @Test func multipleSingletonsInOneFile() {
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }

            @Singleton
            struct B {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Both.swift")
        #expect(result.count == 2)
        #expect(Set(result.map { $0.typeName }) == ["A", "B"])
    }

    // MARK: - Effect-specifier capture

    @Test func injectInitWithoutEffectsHasFalseFlags() {
        // Sync, non-throwing init — both flags default to `false`.
        // Guards against accidentally tagging plain inits as
        // effectful.
        let source = """
            @Singleton
            struct A {
                @Inject init(b: B) {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].initIsAsync == false)
        #expect(result[0].initIsThrowing == false)
    }

    @Test func injectInitWithAsyncCapturesFlag() {
        let source = """
            @Singleton
            struct A {
                @Inject init(b: B) async {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].initIsAsync == true)
        #expect(result[0].initIsThrowing == false)
    }

    @Test func injectInitWithThrowsCapturesFlag() {
        let source = """
            @Singleton
            struct A {
                @Inject init(b: B) throws {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].initIsAsync == false)
        #expect(result[0].initIsThrowing == true)
    }

    @Test func injectInitWithAsyncThrowsCapturesBothFlags() {
        let source = """
            @Singleton
            struct A {
                @Inject init(b: B) async throws {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].initIsAsync == true)
        #expect(result[0].initIsThrowing == true)
    }

    @Test func injectPropertySynthesizedInitIsSync() {
        // Macro-synthesised init (from `@Inject` stored properties)
        // is always sync, non-throwing — it's a memberwise store of
        // already-resolved values. Effect flags stay `false`.
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].initIsAsync == false)
        #expect(result[0].initIsThrowing == false)
    }

    @Test func providesFunctionWithEffectsCapturesFlags() {
        let source = """
            @Provides
            func makeAsync() async -> Foo { Foo() }

            @Provides
            func makeThrows() throws -> Bar { Bar() }

            @Provides
            func makeBoth() async throws -> Baz { Baz() }

            @Provides
            func makeSync() -> Qux { Qux() }
            """
        let result = discoverProviders(in: source, sourcePath: "Source.swift")
        let byType = Dictionary(uniqueKeysWithValues: result.map { ($0.boundType, $0) })
        #expect(byType["Foo"]?.isAsync == true)
        #expect(byType["Foo"]?.isThrowing == false)
        #expect(byType["Bar"]?.isAsync == false)
        #expect(byType["Bar"]?.isThrowing == true)
        #expect(byType["Baz"]?.isAsync == true)
        #expect(byType["Baz"]?.isThrowing == true)
        #expect(byType["Qux"]?.isAsync == false)
        #expect(byType["Qux"]?.isThrowing == false)
    }

    @Test func providesComputedPropertyWithEffectsCapturesFlags() {
        // Computed `@Provides var x: T { get async throws { ... } }`
        // — accessor effect specifiers propagate the same way as
        // function ones.
        let source = """
            @Provides
            var asyncFoo: Foo {
                get async { Foo() }
            }

            @Provides
            var throwingBar: Bar {
                get throws { Bar() }
            }

            @Provides
            var bothBaz: Baz {
                get async throws { Baz() }
            }
            """
        let result = discoverProviders(in: source, sourcePath: "Source.swift")
        let byType = Dictionary(uniqueKeysWithValues: result.map { ($0.boundType, $0) })
        #expect(byType["Foo"]?.isAsync == true)
        #expect(byType["Foo"]?.isThrowing == false)
        #expect(byType["Bar"]?.isAsync == false)
        #expect(byType["Bar"]?.isThrowing == true)
        #expect(byType["Baz"]?.isAsync == true)
        #expect(byType["Baz"]?.isThrowing == true)
    }

    @Test func providesStoredPropertyHasNoEffects() {
        // `@Provides let logger = Logger()` — stored binding, no
        // accessor, so no effect specifiers possible. Flags stay
        // `false`.
        let source = """
            @Provides let logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "Source.swift")
        #expect(result.count == 1)
        #expect(result[0].isAsync == false)
        #expect(result[0].isThrowing == false)
    }

    // MARK: - Scope blocks: `@Scoped(seed:)` enum (Axis A)

    @Test func plainProvidesHasNoScopeKey() {
        // A `@Provides` outside any scope block stays in the default graph.
        let source = """
            @Provides func makeFoo() -> Foo { Foo() }
            """
        let result = discoverProviders(in: source, sourcePath: "Source.swift")
        #expect(result.count == 1)
        #expect(result[0].scopeKey == nil)
    }

    @Test func providesInScopeBlockInheritsTheBlockSeed() {
        // Both the function and property forms inherit the enclosing
        // `@Scoped(seed:)` enum's seed — no per-producer annotation.
        let source = """
            @Scoped(seed: RequestSeed.self)
            enum RequestProviders {
                @Provides static func makeFoo() -> Foo { Foo() }
                @Provides static let bar: Bar = Bar()
            }
            """
        let result = discoverProviders(
            in: source,
            sourcePath: "Source.swift",
            partition: Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))
        )
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.scopeKey == ScopeKey(seed: "RequestSeed") })
    }

    @Test func scopeBlockRoutesProvidersOutOfDefaultGraph() {
        // The block's producers land in `(nil, RequestSeed)`, the same
        // cell a `@Scoped(seed:)` *type* would occupy — not the default.
        let source = """
            @Scoped(seed: RequestSeed.self)
            enum RequestProviders {
                @Provides static func makeFoo() -> Foo { Foo() }
            }
            """
        let partitions = discover(in: source, sourcePath: "Source.swift", module: testModule).allBindings
        let seedPartition = Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))
        #expect(partitions[seedPartition]?.count == 1)
        #expect(partitions[Partition(container: nil, scope: nil)] == nil)
    }

    @Test func scopeBlockInContainerLandsInContainerSeedPartition() {
        // Both axes engage: the `@Container` enum sets the container axis,
        // the nested `@Scoped(seed:)` enum sets the scope axis.
        let source = """
            @Container
            enum App {
                @Scoped(seed: RequestSeed.self)
                enum Providers {
                    @Provides static func makeFoo() -> Foo { Foo() }
                }
            }
            """
        let partitions = discover(in: source, sourcePath: "Source.swift", module: testModule).allBindings
        let cell = Partition(container: "App", scope: ScopeKey(seed: "RequestSeed"))
        #expect(partitions[cell]?.count == 1)
    }

    @Test func scopedTypeInsideBlockKeepsItsOwnSeed() {
        // A self-producing `@Scoped(seed:)` type carries its own scope; it
        // does not inherit a different enclosing block's seed.
        let source = """
            @Scoped(seed: OuterSeed.self)
            enum Block {
                @Scoped(seed: InnerSeed.self)
                struct Worker {
                    @Inject var dep: Dep
                }
            }
            """
        let partitions = discover(in: source, sourcePath: "Source.swift", module: testModule).allBindings
        let ownCell = Partition(container: nil, scope: ScopeKey(seed: "InnerSeed"))
        #expect(partitions[ownCell]?.count == 1)
        #expect(partitions[Partition(container: nil, scope: ScopeKey(seed: "OuterSeed"))] == nil)
    }

    // MARK: - `@Singleton` inside a scope block (Axis A)

    @Test func singletonInScopeBlockIsError() {
        // A @Singleton in a @Scoped block would silently route to the
        // process graph (ignoring the block); flag it instead.
        let source = """
            @Scoped(seed: RequestSeed.self)
            enum RequestProviders {
                @Singleton struct Worker {}
            }
            """
        let result = discover(in: source, sourcePath: "Source.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Singleton 'Worker' can't live in") == true)
        #expect(errors.first?.message.contains("RequestSeed") == true)
    }

    @Test func scopedTypeInScopeBlockIsNotError() {
        // A @Scoped type carries its own seed, so it's fine inside a block.
        let source = """
            @Scoped(seed: OuterSeed.self)
            enum Block {
                @Scoped(seed: InnerSeed.self)
                struct Worker { @Inject var dep: Dep }
            }
            """
        let result = discover(in: source, sourcePath: "Source.swift", module: testModule)
        #expect(result.warnings.contains { $0.message.contains("can't live in") } == false)
    }

    @Test func singletonOutsideScopeBlockIsNotError() {
        let source = """
            @Singleton struct Worker {}
            """
        let result = discover(in: source, sourcePath: "Source.swift", module: testModule)
        #expect(result.warnings.contains { $0.message.contains("can't live in") } == false)
    }

    // MARK: - Member injection: `@Inject weak var` sugar + `@Inject func`

    @Test func weakInjectVarBecomesPropertyAssignmentMemberInjection() {
        // `@Inject weak var x: T?` is sugar for a member injection
        // with `.propertyAssignment` shape. Discovery keeps the full
        // declared type (`Coordinator?`) — type identity stays honest;
        // the graph resolver promotes it against the `Coordinator`
        // producer (asymmetric optional promotion). See
        // OptionalMatchingAndCycles.md.
        let source = """
            @Singleton
            final class View {
                @Inject weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
        #expect(result[0].memberInjections.count == 1)
        let injection = result[0].memberInjections[0]
        #expect(injection.shape == .propertyAssignment(propertyName: "coordinator"))
        #expect(injection.parameters.count == 1)
        #expect(injection.parameters[0].type == "Coordinator?")
        #expect(injection.parameters[0].kind == .injectMethodParameter)
        #expect(injection.isAsync == false)
        #expect(injection.isThrowing == false)
    }

    @Test func weakInjectVarWithIUOBecomesPropertyAssignmentMemberInjection() {
        // The IUO spelling `weak var x: T!` is recognized the same as
        // `T?` — weak detection keys on the `weak` modifier, not the
        // optional sugar. Discovery captures the full declared type
        // (`Coordinator!`, an `ImplicitlyUnwrappedOptionalTypeSyntax`
        // node); the graph resolver normalizes the IUO and promotes it
        // against the `Coordinator` producer. See
        // OptionalMatchingAndCycles.md.
        let source = """
            @Singleton
            final class View {
                @Inject weak var coordinator: Coordinator!
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
        #expect(result[0].memberInjections.count == 1)
        let injection = result[0].memberInjections[0]
        #expect(injection.shape == .propertyAssignment(propertyName: "coordinator"))
        #expect(injection.parameters.count == 1)
        #expect(injection.parameters[0].type == "Coordinator!")
        #expect(injection.parameters[0].kind == .injectMethodParameter)
    }

    @Test func weakInjectLetBecomesInitDependencyNotMemberInjection() {
        // `@Inject weak let x: T?` is delivered at construction (the one
        // write a `let` allows), so it's an ordinary init-time dependency
        // — NOT a post-construct member injection like `weak var`. The
        // declared optional type is kept and promotes against the `T`
        // producer at resolution. See OptionalMatchingAndCycles.md.
        let source = """
            @Singleton
            final class View {
                @Inject weak let coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].memberInjections.isEmpty)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].type == "Coordinator?")
        #expect(result[0].dependencies[0].kind == .injectProperty)
        // Flagged so the cyclic-dependency error can point at it if it
        // closes a cycle.
        #expect(result[0].dependencies[0].nonOwningInitForm == .weakLet)
    }

    @Test func weakInjectLetEmitsNoBlanketDiagnostic() {
        // A `weak let` is a legitimate non-owning, immutable reference
        // (SE-0481); discovery emits NO per-declaration warning. Cycle
        // guidance is a note on the cyclic-dependency error (graph layer),
        // emitted only when a `weak let` actually closes a cycle. See
        // OptionalMatchingAndCycles.md.
        let source = """
            @Singleton
            final class View {
                @Inject weak let coordinator: Coordinator?
            }
            """
        let result = discover(in: source, sourcePath: "View.swift", module: testModule)
        #expect(result.warnings.isEmpty)
    }

    @Test func weakInjectLetWithIUOBecomesInitDependency() {
        // `weak let x: T!` (IUO) is constructor-injected just like
        // `weak let x: T?`; the declared type is kept and promotes against
        // the `T` producer (the IUO normalizes to optional). Parallels the
        // `weak var x: T!` case. See OptionalMatchingAndCycles.md.
        let source = """
            @Singleton
            final class View {
                @Inject weak let coordinator: Coordinator!
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].memberInjections.isEmpty)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].type == "Coordinator!")
        #expect(result[0].dependencies[0].kind == .injectProperty)
        #expect(result[0].dependencies[0].nonOwningInitForm == .weakLet)
    }

    @Test func privateWeakInjectLetEmitsNoTooPrivateError() {
        // A `weak let` is constructor-injected (the macro writes the init
        // in the host scope, which the bootstrap calls), so — like a
        // non-weak `@Inject private let` — it can be `private`. None of
        // the `weak var` post-construct `≥internal` / setter-restriction
        // errors apply. See OptionalMatchingAndCycles.md and
        // VisibilityModel.md.
        let source = """
            @Singleton
            final class View {
                @Inject private weak let coordinator: Coordinator?
            }
            """
        let result = discover(in: source, sourcePath: "View.swift", module: testModule)
        #expect(result.warnings.isEmpty)
    }

    @Test func unownedInjectBecomesInitDependencyFlaggedNonOwning() {
        // `@Inject unowned let/var x: B` is constructor-injected like a
        // non-weak property (non-optional storage can't be deferred
        // post-construct), but is flagged non-owning so a cyclic-dependency
        // error can point at it. `unowned` is NOT a cycle-breaker. See
        // OptionalMatchingAndCycles.md.
        let source = """
            @Singleton
            final class View {
                @Inject unowned let coordinator: Coordinator
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].memberInjections.isEmpty)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].type == "Coordinator")
        #expect(result[0].dependencies[0].nonOwningInitForm == .unowned)
        // No blanket diagnostic for an acyclic unowned reference.
        #expect(discover(in: source, sourcePath: "View.swift", module: testModule).warnings.isEmpty)
    }

    // MARK: - SE-0491 module selectors

    @Test func moduleSelectorTypeCapturedVerbatim() {
        // A module-selector-qualified bound type (`ModuleA::Service`) is
        // captured verbatim — Wire matches by string identity and re-emits
        // the original text into codegen, so the `::` round-trips. See
        // MultiModuleComposition.md.
        let source = """
            @Provides func makeService() -> ModuleA::Service { fatalError() }
            """
        let result = discoverProviders(in: source, sourcePath: "Service.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "ModuleA::Service")
    }

    @Test func moduleQualifiedWireMacrosRecognized() {
        // SE-0491 lets users qualify Wire's macros with its module to
        // disambiguate a macro-name clash (`@Wire::Singleton`,
        // `@Wire::Inject`, …). Discovery recognises the qualified forms the
        // same as the bare ones — for every Wire macro, via the shared
        // attribute matcher. See MultiModuleComposition.md.
        let source = """
            @Wire::Singleton
            final class View {
                @Wire::Inject var logger: Logger
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "View")
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].type == "Logger")
    }

    @Test func otherModuleQualifiedMacroNotRecognizedAsWire() {
        // Only *Wire's own* selector is stripped — `@OtherDI::Singleton` is
        // a different module's macro and must NOT be treated as Wire's
        // `@Singleton`.
        let source = """
            @OtherDI::Singleton
            final class View {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.isEmpty)
    }

    @Test func injectFuncBecomesMethodCallMemberInjection() {
        // The general form: `@Inject func setX(_ x: T)` captures the
        // method's parameter list as the injection's parameters and
        // records the function name for the post-init call site.
        let source = """
            @Singleton
            final class View {
                @Inject
                func receiveCoordinator(_ coordinator: Coordinator) {
                    // user wires storage however they like
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
        let injection = try! #require(result[0].memberInjections.first)
        #expect(injection.shape == .methodCall(methodName: "receiveCoordinator"))
        #expect(injection.parameters.count == 1)
        #expect(injection.parameters[0].type == "Coordinator")
        #expect(injection.parameters[0].name == nil)  // wildcard `_` label
        #expect(injection.parameters[0].kind == .injectMethodParameter)
    }

    @Test func injectFuncCapturesEffectSpecifiers() {
        // `async throws` on an `@Inject func` propagates to the
        // member injection; codegen emits `try await consumer.method(...)`
        // at the post-init call site.
        let source = """
            @Singleton
            final class View {
                @Inject
                func setup(db: Database) async throws {
                    try await db.warmUp()
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        let injection = try! #require(result[0].memberInjections.first)
        #expect(injection.isAsync)
        #expect(injection.isThrowing)
    }

    @Test func nonWeakInjectPropertyStaysInInitDependencies() {
        // Symmetry check: without `weak`, the property stays as an
        // init-time dep (`.injectProperty`), the type isn't unwrapped,
        // and `memberInjections` is empty.
        let source = """
            @Singleton
            final class View {
                @Inject var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.count == 1)
        #expect(result[0].memberInjections.isEmpty)
        let dep = result[0].dependencies[0]
        #expect(dep.kind == .injectProperty)
        #expect(dep.type == "Coordinator?")
    }

    @Test func weakAndStrongInjectPropertiesPartitionAcrossInitAndMemberInjections() {
        // Mixed shape: strong @Inject vars stay in `dependencies`
        // (delivered through the synthesised init); weak @Inject vars
        // move to `memberInjections` (delivered post-construct).
        let source = """
            @Singleton
            final class View {
                @Inject var name: String
                @Inject weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == "name")
        #expect(result[0].memberInjections.count == 1)
        #expect(
            result[0].memberInjections[0].shape == .propertyAssignment(propertyName: "coordinator")
        )
    }

    @Test func mutatingInjectFuncOnStructEmitsErrorDiagnostic() {
        // `@Inject mutating func` on a struct is structurally broken
        // under Wire's codegen — value-copy semantics mean consumers
        // that received the struct via init see the pre-mutation
        // state, while only the graph-stored value reflects the
        // mutation. Discovery raises an error-severity diagnostic
        // so WireGen fails the build before any bad code is
        // emitted. The injection itself is dropped from the
        // result to avoid cluttering downstream analysis.
        let source = """
            @Singleton
            struct Config {
                private(set) var data: SomeData?

                @Inject
                mutating func receive(data: SomeData) {
                    self.data = data
                }
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("'@Inject mutating func' on a struct"))
        #expect(errors[0].message.contains("divergent state"))
        // The injection isn't recorded — it would produce code that
        // won't compile and the user has been told the pattern is
        // invalid.
        guard case .scopeBound(let scopeBound) = result.bindings.first else {
            Issue.record("expected a scope-bound binding")
            return
        }
        #expect(scopeBound.memberInjections.isEmpty)
    }

    @Test func mutatingInjectFuncOnClassDoesNotEmitDiagnostic() {
        // The mutating-on-struct check is structural, not just
        // about `mutating` — classes don't have the value-copy
        // problem (mutation goes through a reference, all
        // consumers see the same instance), so `mutating` on a
        // class method isn't even valid Swift in the first place.
        // The diagnostic doesn't fire for class hosts.
        let source = """
            @Singleton
            final class Config {
                @Inject
                func receive(data: SomeData) {
                    // body
                }
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func nonMutatingInjectFuncOnStructIsAllowed() {
        // A non-mutating `@Inject func` on a struct is the
        // legitimate pattern for "this struct manages its own
        // shared state through an internal reference"
        // (Mutex-wrapped storage, etc.). No diagnostic fires.
        let source = """
            @Singleton
            struct Cache {
                private let storage: Mutex<[String: Data]>

                @Inject
                func warmUp(seed: SeedData) {
                    storage.withLock { $0 = seed.entries }
                }
            }
            """
        let result = discover(in: source, sourcePath: "Cache.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    // MARK: - Access level capture

    @Test func singletonWithoutAccessModifierDefaultsToInternal() {
        let source = """
            @Singleton
            struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.first?.accessLevel == .internal)
    }

    @Test func publicSingletonCapturedAsPublic() {
        let source = """
            @Singleton
            public struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.first?.accessLevel == .public)
    }

    @Test func privateSingletonCapturedAsPrivate() {
        let source = """
            @Singleton
            private struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.first?.accessLevel == .private)
    }

    @Test func fileprivateSingletonCapturedAsFileprivate() {
        let source = """
            @Singleton
            fileprivate struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.first?.accessLevel == .fileprivate)
    }

    @Test func packageSingletonCapturedAsPackage() {
        let source = """
            @Singleton
            package struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.first?.accessLevel == .package)
    }

    @Test func providesLetAccessLevelCaptured() {
        let source = """
            @Provides public let foo: Foo = Foo()
            """
        let result = discoverProviders(in: source, sourcePath: "Foo.swift")
        #expect(result.first?.accessLevel == .public)
    }

    @Test func providesFuncAccessLevelCaptured() {
        let source = """
            @Provides package func makeFoo() -> Foo { Foo() }
            """
        let result = discoverProviders(in: source, sourcePath: "Foo.swift")
        #expect(result.first?.accessLevel == .package)
    }

    @Test func injectWeakVarAccessLevelCaptured() {
        // The weak property's own access modifier is captured on the
        // member injection. Iteration 5α uses this to drive the
        // declaration-too-private check: @Inject private weak var
        // would fail because Wire's bootstrap writes to the property
        // post-construct from a separate file.
        let source = """
            @Singleton
            class View {
                @Inject public weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.first?.memberInjections.first?.accessLevel == .public)
    }

    @Test func injectFuncAccessLevelCaptured() {
        let source = """
            @Singleton
            class View {
                @Inject package func receive(x: T) {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.first?.memberInjections.first?.accessLevel == .package)
    }

    @Test func privateSetOnProvidesVarReturnsBareReadAccess() {
        // `public private(set) var foo` has public read access; the
        // `private(set)` restricts only the setter, which Wire never
        // touches on a `@Provides` (the bootstrap reads the property).
        // So the captured access level matches the bare modifier.
        let source = """
            @Provides public private(set) var foo: Foo = Foo()
            """
        let result = discoverProviders(in: source, sourcePath: "Foo.swift")
        #expect(result.first?.accessLevel == .public)
    }

    @Test func privateSetWithoutBareModifierFallsBackToInternalRead() {
        // `private(set) var foo` with no other access modifier has
        // read access at Swift's default — `.internal`. The
        // `private(set)` restricts only the setter and doesn't
        // contribute to the property's read visibility.
        let source = """
            @Provides private(set) var foo: Foo = Foo()
            """
        let result = discoverProviders(in: source, sourcePath: "Foo.swift")
        #expect(result.first?.accessLevel == .internal)
    }

    @Test func injectWeakVarWithoutSetterRestrictionHasNilSetterAccessLevel() {
        // Default case: no `(set)` modifier means the setter
        // inherits the property's read access. The captured
        // `setterAccessLevel` is `nil` to distinguish "explicitly
        // restricted" from "inherits from read access."
        let source = """
            @Singleton
            class View {
                @Inject internal weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        let injection = try! #require(result.first?.memberInjections.first)
        #expect(injection.setterAccessLevel == nil)
        #expect(injection.effectiveWriteAccessLevel == .internal)
    }

    @Test func injectWeakVarWithPrivateSetCapturesSetterRestriction() {
        // `private(set)` restricts the setter independently of the
        // property's read access. Wire's bootstrap writes to the
        // property post-construct; the captured setter level lets
        // the diagnostic recognise the case and emit a tailored
        // error.
        let source = """
            @Singleton
            class View {
                @Inject internal private(set) weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        let injection = try! #require(result.first?.memberInjections.first)
        #expect(injection.accessLevel == .internal)
        #expect(injection.setterAccessLevel == .private)
        #expect(injection.effectiveWriteAccessLevel == .private)
    }

    @Test func injectWeakVarWithFileprivateSetCapturesSetterRestriction() {
        let source = """
            @Singleton
            class View {
                @Inject public fileprivate(set) weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        let injection = try! #require(result.first?.memberInjections.first)
        #expect(injection.accessLevel == .public)
        #expect(injection.setterAccessLevel == .fileprivate)
        #expect(injection.effectiveWriteAccessLevel == .fileprivate)
    }

    @Test func injectWeakVarWithInternalSetCapturesSetterRestriction() {
        // `internal(set)` is a less restrictive case — the setter
        // is still reachable from Wire's generated bootstrap.
        // Captured for completeness; the diagnostic step will treat
        // it the same as no restriction at all.
        let source = """
            @Singleton
            class View {
                @Inject public internal(set) weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        let injection = try! #require(result.first?.memberInjections.first)
        #expect(injection.accessLevel == .public)
        #expect(injection.setterAccessLevel == .internal)
        #expect(injection.effectiveWriteAccessLevel == .internal)
    }

    @Test func injectFuncDoesNotCaptureSetterAccessLevel() {
        // Functions don't have separate getter/setter access — the
        // captured `setterAccessLevel` is `nil` on `.methodCall`
        // injections regardless of what's in the source.
        let source = """
            @Singleton
            class View {
                @Inject public func receive(x: T) {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        let injection = try! #require(result.first?.memberInjections.first)
        #expect(injection.setterAccessLevel == nil)
        #expect(injection.effectiveWriteAccessLevel == .public)
    }

    @Test func accessLevelHelperVisibilityChecks() {
        // The two convenience predicates that drive 5α's diagnostics:
        // isVisibleToGeneratedCode (`internal+`) and isPubliclyExposed
        // (`public`/`open`).
        #expect(AccessLevel.public.isVisibleToGeneratedCode == true)
        #expect(AccessLevel.package.isVisibleToGeneratedCode == true)
        #expect(AccessLevel.internal.isVisibleToGeneratedCode == true)
        #expect(AccessLevel.fileprivate.isVisibleToGeneratedCode == false)
        #expect(AccessLevel.private.isVisibleToGeneratedCode == false)
        #expect(AccessLevel.open.isPubliclyExposed == true)
        #expect(AccessLevel.public.isPubliclyExposed == true)
        #expect(AccessLevel.package.isPubliclyExposed == false)
        #expect(AccessLevel.internal.isPubliclyExposed == false)
    }

    // MARK: - Declaration-too-private diagnostics

    @Test func privateSingletonEmitsDeclarationTooPrivateError() {
        let source = """
            @Singleton
            private struct Hidden {
            }
            """
        let result = discover(in: source, sourcePath: "Hidden.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Singleton type 'Hidden'") == true)
        #expect(errors.first?.message.contains("'private'") == true)
        #expect(errors.first?.message.contains("must be at least 'internal'") == true)
    }

    @Test func fileprivateSingletonEmitsDeclarationTooPrivateError() {
        let source = """
            @Singleton
            fileprivate struct Hidden {
            }
            """
        let result = discover(in: source, sourcePath: "Hidden.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("'fileprivate'") == true)
    }

    @Test func privateScopedEmitsDeclarationTooPrivateError() {
        let source = """
            @Scoped(seed: SessionSeed.self)
            private struct Hidden {
            }
            """
        let result = discover(in: source, sourcePath: "Hidden.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Scoped type 'Hidden'") == true)
    }

    @Test func internalSingletonDoesNotEmitDeclarationTooPrivateError() {
        // Boundary check: the default access (`internal`) is visible
        // to the generated bootstrap file, so no error fires.
        let source = """
            @Singleton
            struct Visible {
            }
            """
        let result = discover(in: source, sourcePath: "Visible.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func privateProvidesLetEmitsDeclarationTooPrivateError() {
        let source = """
            @Provides private let logger: Logger = Logger()
            """
        let result = discover(in: source, sourcePath: "Logger.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Provides declaration 'logger'") == true)
        #expect(errors.first?.message.contains("'private'") == true)
    }

    @Test func fileprivateProvidesFuncEmitsDeclarationTooPrivateError() {
        let source = """
            @Provides fileprivate func makeLogger() -> Logger { Logger() }
            """
        let result = discover(in: source, sourcePath: "Logger.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Provides function 'makeLogger'") == true)
        #expect(errors.first?.message.contains("'fileprivate'") == true)
    }

    @Test func privateInjectInitEmitsDeclarationTooPrivateError() {
        let source = """
            @Singleton
            struct Service {
                @Inject private init(logger: Logger) {}
            }
            """
        let result = discover(in: source, sourcePath: "Service.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Inject init") == true)
        #expect(errors.first?.message.contains("'private'") == true)
    }

    @Test func privateInjectWeakVarEmitsErrorWithAsymmetryNote() {
        let source = """
            @Singleton
            class View {
                @Inject private weak var coordinator: Coordinator?
            }
            """
        let result = discover(in: source, sourcePath: "View.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Inject weak var 'coordinator'") == true)
        #expect(errors.first?.notes.count == 1)
        #expect(errors.first?.notes.first?.message.contains("can be 'private'") == true)
        #expect(errors.first?.notes.first?.message.contains("post-construct delivery") == true)
    }

    @Test func privateSetOnPublicInjectWeakVarEmitsSetterRestrictionError() {
        let source = """
            @Singleton
            class View {
                @Inject public private(set) weak var coordinator: Coordinator?
            }
            """
        let result = discover(in: source, sourcePath: "View.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("setter is 'private(set)'") == true)
        #expect(errors.first?.notes.first?.message.contains("Drop the setter restriction") == true)
    }

    @Test func privateInjectFuncEmitsErrorWithAsymmetryNote() {
        let source = """
            @Singleton
            class View {
                @Inject private func receive(data: Data) {}
            }
            """
        let result = discover(in: source, sourcePath: "View.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Inject func 'receive'") == true)
        #expect(errors.first?.notes.count == 1)
        #expect(errors.first?.notes.first?.message.contains("can be 'private'") == true)
    }

    @Test func declarationTooPrivateInjectWeakVarStillCapturesInjection() {
        // Error severity already fails the build before codegen, so
        // the injection is still emitted into the discovery result —
        // consistency with how `@Singleton` / `@Provides` errors don't
        // skip their bindings either.
        let source = """
            @Singleton
            class View {
                @Inject private weak var coordinator: Coordinator?
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.first?.memberInjections.count == 1)
    }

    @Test func declarationTooPrivateInjectFuncStillCapturesInjection() {
        let source = """
            @Singleton
            class View {
                @Inject private func receive(data: Data) {}
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "View.swift")
        #expect(result.first?.memberInjections.count == 1)
    }

    // MARK: - Declaration-too-private via enclosing scope

    @Test func providesInPrivateEnclosingEnumEmitsDeclarationTooPrivateError() {
        // The canonical caseless-enum-as-namespace pattern, but the
        // enclosing enum is `private`. The `@Provides` itself carries no
        // modifier (so reads as `internal` in isolation), yet Swift caps
        // its effective access at `private` — unreachable from Wire's
        // bootstrap. The diagnostic must name the enum, not the binding.
        let source = """
            private enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Provides declaration 'baseURL'") == true)
        #expect(errors.first?.message.contains("effectively 'private'") == true)
        #expect(errors.first?.message.contains("enclosing scope 'Config' is 'private'") == true)
        #expect(errors.first?.message.contains("Raise 'Config'") == true)
    }

    @Test func providesFuncInFileprivateEnclosingEnumEmitsDeclarationTooPrivateError() {
        let source = """
            fileprivate enum Config {
                @Provides static func makeLogger() -> Logger { Logger() }
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Provides function 'makeLogger'") == true)
        #expect(errors.first?.message.contains("effectively 'fileprivate'") == true)
        #expect(errors.first?.message.contains("enclosing scope 'Config' is 'fileprivate'") == true)
    }

    @Test func singletonNestedInPrivateTypeEmitsDeclarationTooPrivateError() {
        // The nested type's own modifier is `internal`, but the
        // `private` outer struct caps it. The `@Singleton` surface
        // catches the enclosing restriction the same way `@Provides`
        // does.
        let source = """
            private struct Outer {
                @Singleton
                struct Inner {
                }
            }
            """
        let result = discover(in: source, sourcePath: "Outer.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Singleton type 'Inner'") == true)
        #expect(errors.first?.message.contains("enclosing scope 'Outer' is 'private'") == true)
    }

    @Test func providesInInternalEnclosingEnumDoesNotEmitError() {
        // Boundary: an `internal` (default) enclosing enum is visible to
        // the generated bootstrap, so a non-annotated `@Provides` inside
        // it stays reachable — no error.
        let source = """
            enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func providesInPublicEnclosingEnumDoesNotEmitError() {
        let source = """
            public enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func providesInNestedEnumsBlamesMostRestrictiveEnclosingScope() {
        // The binding sits inside a `public` inner enum nested in a
        // `private` outer enum. The effective access is `private`, and
        // the diagnostic must point at the outer enum — the actual
        // limiter — not the innocuous `public` inner one.
        let source = """
            private enum Outer {
                public enum Inner {
                    @Provides static let baseURL: URL = URL(string: "...")!
                }
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("enclosing scope 'Outer' is 'private'") == true)
    }

    @Test func ownPrivateModifierWinsOverEnclosingScopeInDiagnostic() {
        // When the binding's own modifier is already too private, that's
        // the primary fix — the message uses the own-modifier wording
        // ("is 'private' but must be") rather than redirecting blame to
        // the enclosing scope.
        let source = """
            private enum Config {
                @Provides private static let baseURL: URL = URL(string: "...")!
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        let errors = result.warnings.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("@Provides declaration 'baseURL' is 'private'") == true)
        #expect(errors.first?.message.contains("effectively") == false)
    }

    // MARK: - Parameter name edge cases

    @Test func injectInitWithWildcardParameterLabel() {
        // `init(_ a: A)` — wildcard external label. Wire captures `nil`
        // for the name so the type system forces code emission to
        // handle the "omit the label" case explicitly, rather than
        // sneaking through as a `"_"` sentinel that downstream might
        // accidentally emit literally.
        let source = """
            @Singleton
            struct X {
                @Inject
                init(_ a: A) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "X.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == nil)
        #expect(result[0].dependencies[0].type == "A")
    }

    @Test func injectInitWithExternalAndInternalLabels() {
        // `init(label internalName: A)` — both names set. The external
        // label "label" is what callers write at the call site, so
        // that's what Wire captures. The internal name "internalName"
        // is an implementation detail of the init body, irrelevant to
        // Wire's bootstrap codegen.
        let source = """
            @Singleton
            struct X {
                @Inject
                init(label internalName: A) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "X.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies[0].name == "label")
    }

    @Test func injectPropertyWithoutTypeAnnotationIsSkipped() {
        // `@Inject var x = SomeFactory.make()` — type-inferred property.
        // The macro would normally reject this; WireGen is downstream of
        // that and takes a best-effort posture: a property without a
        // type annotation can't be turned into an injection point.
        let source = """
            @Singleton
            struct X {
                @Inject var x = 5
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "X.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
    }

    // MARK: - @Provides discovery

    @Test func providesOnTopLevelLetIsDiscovered() {
        let source = """
            @Provides let logger: Logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
        #expect(result[0].accessPath == "logger")
        #expect(result[0].form == .property)
        #expect(result[0].dependencies.isEmpty)
        #expect(result[0].sourcePath == "App.swift")
    }

    @Test func providesOnTopLevelFuncWithoutParametersIsDiscovered() {
        let source = """
            @Provides
            func makeLogger() -> Logger {
                Logger()
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
        #expect(result[0].accessPath == "makeLogger")
        #expect(result[0].form == .function)
        #expect(result[0].dependencies.isEmpty)
    }

    @Test func providesOnTopLevelFuncWithParametersBecomesDependencies() {
        let source = """
            @Provides
            func makeRepository(table: TaskTable, logger: Logger) -> Repository {
                Repository(table: table, logger: logger)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 2)
        #expect(result[0].dependencies[0].name == "table")
        #expect(result[0].dependencies[0].type == "TaskTable")
        #expect(result[0].dependencies[0].kind == .providerFunctionParameter)
        #expect(result[0].dependencies[1].name == "logger")
        #expect(result[0].dependencies[1].type == "Logger")
    }

    @Test func providesOnStaticLetCapturesEnclosingTypeInAccessPath() {
        let source = """
            enum Config {
                @Provides static let dbURL: URL = URL(string: "...")!
            }
            """
        let result = discoverProviders(in: source, sourcePath: "Config.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "URL")
        #expect(result[0].accessPath == "Config.dbURL")
        #expect(result[0].form == .property)
    }

    @Test func providesOnStaticFuncCapturesEnclosingTypeInAccessPath() {
        let source = """
            struct AppConfig {
                @Provides
                static func makeClient() -> HTTPClient {
                    HTTPClient()
                }
            }
            """
        let result = discoverProviders(in: source, sourcePath: "AppConfig.swift")
        #expect(result.count == 1)
        #expect(result[0].accessPath == "AppConfig.makeClient")
        #expect(result[0].form == .function)
    }

    @Test func providesNestedInsideTypesProducesDottedAccessPath() {
        // Caseless-enum-as-namespace pattern with nested namespacing.
        // Access path joins enclosing types with `.`, just like Swift
        // call-site syntax.
        let source = """
            enum Outer {
                enum Inner {
                    @Provides static let foo: Foo = Foo()
                }
            }
            """
        let result = discoverProviders(in: source, sourcePath: "N.swift")
        #expect(result.count == 1)
        #expect(result[0].accessPath == "Outer.Inner.foo")
    }

    @Test func providesOnInstanceMemberIsSkipped() {
        // Instance members have no resolvable construction path, so
        // `@Provides` on them is silently ignored.
        let source = """
            struct AppConfig {
                @Provides let logger: Logger = Logger()
            }
            """
        let result = discoverProviders(in: source, sourcePath: "AppConfig.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetInferredFromConstructorCallIsDiscovered() {
        // Idiomatic Swift form: `let x = Foo()` with no annotation.
        // The bound type is inferred from the called constructor.
        let source = """
            @Provides let logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
        #expect(result[0].accessPath == "logger")
    }

    @Test func providesLetInferredFromGenericConstructorCall() {
        // `let x = Foo<Bar>()` — the generic specialisation is part of
        // the inferred type.
        let source = """
            @Provides let repo = Repository<TaskTable>()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Repository<TaskTable>")
    }

    @Test func providesLetWithDotInitFormIsDiscovered() {
        // `let x: Type = .init()` — annotation present, RHS isn't read.
        // This was already supported but pin the behaviour with a test.
        let source = """
            @Provides let logger: Logger = .init()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
    }

    @Test func providesLetFromMemberAccessIsSkipped() {
        // `let x = Foo.shared` — we can't tell what type `shared`
        // resolves to without running type inference. Skip silently;
        // the user can add an explicit annotation.
        let source = """
            @Provides let logger = Logger.shared
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetFromLowercaseFunctionCallIsSkipped() {
        // `let x = makeFoo()` — calls a function. By Swift convention
        // a lowercase-first identifier isn't a type, so we don't
        // misidentify the function name as the bound type.
        let source = """
            @Provides let logger = makeLogger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetFromLiteralIsSkipped() {
        // `let x = 42` — non-call initializers aren't recognised.
        let source = """
            @Provides let answer = 42
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetTypeAnnotationTakesPrecedenceOverConstructorCall() {
        // When both forms are present, the user's annotation is the
        // declared bound type — they may have widened to a protocol or
        // existential that the RHS conforms to.
        let source = """
            @Provides let logger: any Logger = AppLogger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "any Logger")
    }

    @Test func providesOnFuncCapturesGenericParameters() {
        // Generic functions are skipped from the graph at construction
        // time (deferred until concrete specialisation lands), but
        // discovery captures the names so the skip can be reported.
        let source = """
            @Provides
            func makeRepository<T: TaskTable>(table: T) -> Repository<T> {
                Repository(table: table)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].genericParameterNames == ["T"])
    }

    @Test func providesOnVoidReturningFuncIsSkipped() {
        // A `@Provides func` with no return clause produces nothing
        // injectable. The build plugin silently skips it; the macro
        // could later turn this into a diagnostic, but for now it's a
        // no-op rather than a hard error.
        let source = """
            @Provides
            func sideEffect() {
                print("hello")
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesPreservesGenericInstantiationInBoundType() {
        // Concrete generic instantiations as the bound type are
        // supported (the codegen sanitisation handles them when
        // building the property name).
        let source = """
            @Provides
            func makeRepository(table: TaskTable)
                -> DynamoDBRepository<TaskTable>
            {
                DynamoDBRepository(table: table)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "DynamoDBRepository<TaskTable>")
    }

    @Test func mixedSingletonsAndProvidersInOneFile() {
        let source = """
            @Provides let logger: Logger = Logger()

            @Singleton
            struct UserService {
                @Inject var logger: Logger
            }

            enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let bindings = discover(in: source, sourcePath: "Mixed.swift", module: testModule).bindings
        #expect(bindings.count == 3)
        let singletons = bindings.compactMap { binding -> DiscoveredScopeBoundType? in
            if case .scopeBound(let s) = binding { return s }
            return nil
        }
        let providers = bindings.compactMap { binding -> DiscoveredProvider? in
            if case .provider(let p) = binding { return p }
            return nil
        }
        #expect(singletons.count == 1)
        #expect(singletons[0].typeName == "UserService")
        #expect(providers.count == 2)
        #expect(Set(providers.map { $0.accessPath }) == ["logger", "Config.baseURL"])
    }

    // MARK: - @Container discovery

    @Test func providesInsideContainerRoutedToContainerBucket() {
        // @Provides inside a @Container enum lands in the container's
        // bucket, not the default-graph bucket.
        let source = """
            @Container
            enum TestContainer {
                @Provides static let logger: Logger = Logger()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        #expect(result.containerBindings.keys.sorted() == ["TestContainer"])
        let testContainerBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testContainerBindings.count == 1)
        if case .provider(let provider) = testContainerBindings[0] {
            #expect(provider.boundType == "Logger")
            #expect(provider.accessPath == "TestContainer.logger")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func nestedSingletonInsideContainerRoutedToContainerBucket() {
        // A @Singleton declared inside a @Container belongs to that
        // container's graph, not the default graph. The qualified
        // type name captures the full enclosing path so codegen can
        // construct the type from module scope.
        let source = """
            @Container
            enum TestContainer {
                @Singleton
                struct MockService {
                    @Inject var logger: Logger
                }
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        let testContainerBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testContainerBindings.count == 1)
        if case .scopeBound(let scopeBound) = testContainerBindings[0] {
            #expect(scopeBound.typeName == "MockService")
            #expect(scopeBound.qualifiedTypeName == "TestContainer.MockService")
            #expect(scopeBound.dependencies.first?.type == "Logger")
        } else {
            Issue.record("expected singleton binding")
        }
    }

    @Test func topLevelSingletonHasQualifiedTypeNameEqualToTypeName() {
        // For a `@Singleton` at module scope, the qualified type name
        // is just the simple name — codegen needs no enclosing prefix.
        let source = """
            @Singleton
            struct UserService {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserService.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "UserService")
        #expect(result[0].qualifiedTypeName == "UserService")
    }

    @Test func bindingsInNonContainerEnclosingTypeStayInDefaultGraph() {
        // Static @Provides on a non-@Container enum continues to feed
        // the default graph (preserves 2a behaviour).
        let source = """
            enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift", module: testModule)
        #expect(result.bindings.count == 1)
        #expect(result.containerBindings.isEmpty)
    }

    @Test func multipleContainersProduceIndependentBuckets() {
        let source = """
            @Container
            enum ProdContainer {
                @Provides static let logger: Logger = Logger()
            }

            @Container
            enum TestContainer {
                @Provides static let logger: Logger = MockLogger()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        #expect(result.containerBindings.keys.sorted() == ["ProdContainer", "TestContainer"])
        #expect(result.containerBindings["ProdContainer"]?.count == 1)
        #expect(result.containerBindings["TestContainer"]?.count == 1)
    }

    @Test func mixedContainerAndModuleScopeBindingsArePartitioned() {
        let source = """
            @Provides let appName: AppName = AppName(value: "default")

            @Singleton
            struct UserService {
                @Inject var logger: Logger
            }

            @Container
            enum TestContainer {
                @Provides static let appName: AppName = AppName(value: "test")
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        // Default graph: module-scope @Provides + module-scope @Singleton
        #expect(result.bindings.count == 2)
        // Container: just its @Provides
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 1)
        if case .provider(let provider) = testBindings[0] {
            #expect(provider.accessPath == "TestContainer.appName")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func providesInUnannotatedExtensionFallsThroughToDefault() {
        // An extension without its own `@Container` annotation is just
        // an extension — its bindings fall through to the default
        // graph with a `Foo.member`-style access path. Even when the
        // extended type has a `@Container` primary declaration, the
        // extension itself doesn't carry container semantics.
        let source = """
            @Container
            enum TestContainer {
                @Provides static let logger: Logger = Logger()
            }

            extension TestContainer {
                @Provides static let extra: Extra = Extra()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        // The container's primary `@Provides` lands in the container.
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 1)
        if case .provider(let provider) = testBindings[0] {
            #expect(provider.accessPath == "TestContainer.logger")
        } else {
            Issue.record("expected provider binding")
        }
        // The extension's `@Provides` falls through to default with
        // a dotted access path. (Iteration 3 will surface a warning
        // here pointing the user at `@Container extension` or moving
        // the binding into the primary declaration.)
        #expect(result.bindings.count == 1)
        if case .provider(let provider) = result.bindings[0] {
            #expect(provider.accessPath == "TestContainer.extra")
            #expect(provider.boundType == "Extra")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func providesInContainerAnnotatedExtensionMergesIntoContainer() {
        // `@Container extension Foo { ... }` opts the extension into
        // Foo's container — the extension's bindings merge with the
        // primary `@Container enum Foo` declaration's bindings.
        let source = """
            @Container
            enum TestContainer {
                @Provides static let logger: Logger = Logger()
            }

            @Container
            extension TestContainer {
                @Provides static let extra: Extra = Extra()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 2)
        let accessPaths = Set(
            testBindings.compactMap { binding -> String? in
                if case .provider(let provider) = binding {
                    return provider.accessPath
                }
                return nil
            }
        )
        #expect(accessPaths == ["TestContainer.logger", "TestContainer.extra"])
    }

    @Test func containerOnStructRoutesBindingsToContainer() {
        // The README's canonical pattern is `@Container enum`, but
        // any type kind that can carry `static` members works. A
        // `@Container struct` namespace routes its static `@Provides`
        // into the container the same way an enum would.
        let source = """
            @Container
            struct AppConfig {
                @Provides static let logger: Logger = Logger()
            }
            """
        let result = discover(in: source, sourcePath: "AppConfig.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        let bindings = result.containerBindings["AppConfig"] ?? []
        #expect(bindings.count == 1)
        if case .provider(let provider) = bindings.first {
            #expect(provider.accessPath == "AppConfig.logger")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func containerOnClassRoutesBindingsToContainer() {
        let source = """
            @Container
            class TestContainer {
                @Provides static let mockLogger: Logger = MockLogger()
            }
            """
        let result = discover(in: source, sourcePath: "TestContainer.swift", module: testModule)
        let bindings = result.containerBindings["TestContainer"] ?? []
        #expect(bindings.count == 1)
    }

    @Test func containerOnActorRoutesBindingsToContainer() {
        let source = """
            @Container
            actor RuntimeConfig {
                @Provides static let buildNumber: Int = 42
            }
            """
        let result = discover(in: source, sourcePath: "RuntimeConfig.swift", module: testModule)
        let bindings = result.containerBindings["RuntimeConfig"] ?? []
        #expect(bindings.count == 1)
    }

    @Test func containerAnnotatedExtensionWithoutPrimaryDeclarationStillContributes() {
        // The `@Container` annotation on an extension is sufficient on
        // its own — the extended type doesn't need a primary
        // `@Container` declaration in the same source. (Whether one
        // exists in another source file is a cross-file question that
        // the build plugin handles by aggregating per-file results.)
        let source = """
            @Container
            extension SomeType {
                @Provides static let value: Value = Value()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        let bindings = result.containerBindings["SomeType"] ?? []
        #expect(bindings.count == 1)
    }

    @Test func providesInsideHelperTypeNestedInContainerStillRoutesToContainer() {
        // A non-@Container helper struct nested inside a @Container
        // inherits the container scope — its bindings still belong to
        // the enclosing container's graph.
        let source = """
            @Container
            enum TestContainer {
                struct Helper {
                    @Provides static let value: Value = Value()
                }
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 1)
        if case .provider(let provider) = testBindings[0] {
            #expect(provider.accessPath == "TestContainer.Helper.value")
        } else {
            Issue.record("expected provider binding")
        }
    }

    // MARK: - Import discovery

    @Test func discoverImportsFindsPlainImports() {
        let source = """
            import Foundation
            import OSLog

            @Provides let logger: Logger = Logger()
            """
        let imports = discover(in: source, sourcePath: "", module: testModule).imports
        #expect(imports == ["import Foundation", "import OSLog"])
    }

    @Test func discoverImportsPreservesAccessModifiersVerbatim() {
        // @testable, @_implementationOnly, @preconcurrency, etc. need
        // to be propagated verbatim — silently dropping them changes
        // semantics in the generated file.
        let source = """
            import Foundation
            @testable import Internals
            @_implementationOnly import OSLog
            """
        let imports = discover(in: source, sourcePath: "", module: testModule).imports
        #expect(imports.contains("import Foundation"))
        #expect(imports.contains("@testable import Internals"))
        #expect(imports.contains("@_implementationOnly import OSLog"))
    }

    @Test func discoverImportsCapturesScopedImports() {
        // `import struct Foundation.URL` form is supported by Swift
        // and must be preserved as-is.
        let source = """
            import struct Foundation.URL
            import func Foundation.exit
            """
        let imports = discover(in: source, sourcePath: "", module: testModule).imports
        #expect(imports.contains("import struct Foundation.URL"))
        #expect(imports.contains("import func Foundation.exit"))
    }

    @Test func discoverImportsReturnsEmptyForFileWithNoImports() {
        let source = """
            @Singleton
            struct A {
            }
            """
        let imports = discover(in: source, sourcePath: "", module: testModule).imports
        #expect(imports.isEmpty)
    }

    // MARK: - renderDiscoveryReport

    @Test func discoveryReportHeaderAndCountWithEmptyInput() {
        let report = renderDiscoveryReport(perFile: [])
        #expect(report.contains("WireGen discovery report"))
        #expect(report.contains("discovered 0 binding(s) across 0 source file(s)"))
    }

    @Test func discoveryReportSkipsFilesWithNoBindings() {
        // Files that contained no bindings should not appear in the
        // report body; they still count toward "source file(s)" though.
        let item: DiscoveredBinding = .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: WireGenCore.SourceLocation(file: "Found.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [
            (path: "Empty.swift", items: []),
            (path: "Found.swift", items: [item]),
        ])
        #expect(!report.contains("Empty.swift"))
        #expect(report.contains("Found.swift"))
        #expect(report.contains("discovered 1 binding(s) across 2 source file(s)"))
    }

    @Test func discoveryReportRendersSingletonGenerics() {
        let item: DiscoveredBinding = .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Repository",
                typeKind: "struct",
                genericParameterNames: ["Model"],
                dependencies: [],
                location: WireGenCore.SourceLocation(file: "R.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "R.swift", items: [item])])
        #expect(report.contains("@Singleton struct Repository<Model>"))
    }

    @Test func discoveryReportRendersInjectPropertyDependency() {
        let item: DiscoveredBinding = .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "b",
                        type: "B",
                        kind: .injectProperty,
                        location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
                    )
                ],
                location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("b: B"))
        #expect(report.contains("@Inject property"))
    }

    @Test func discoveryReportRendersInjectInitParameterDependency() {
        let item: DiscoveredBinding = .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "b",
                        type: "B",
                        kind: .injectInitParameter,
                        location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
                    )
                ],
                location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("@Inject init parameter"))
    }

    @Test func discoveryReportRendersProviderProperty() {
        let item: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Logger",
                accessPath: "logger",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: WireGenCore.SourceLocation(file: "App.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "App.swift", items: [item])])
        #expect(report.contains("@Provides let logger -> Logger"))
    }

    @Test func discoveryReportRendersProviderFunctionWithParameters() {
        let item: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Repository",
                accessPath: "makeRepository",
                form: .function,
                dependencies: [
                    DependencyParameter(
                        name: "table",
                        type: "TaskTable",
                        kind: .providerFunctionParameter,
                        location: WireGenCore.SourceLocation(file: "App.swift", line: 1, column: 1)
                    )
                ],
                genericParameterNames: [],
                location: WireGenCore.SourceLocation(file: "App.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "App.swift", items: [item])])
        #expect(report.contains("@Provides func makeRepository -> Repository"))
        #expect(report.contains("table: TaskTable"))
        #expect(report.contains("@Provides function parameter"))
    }

    @Test func discoveryReportShowsNoDependenciesNoticeWhenEmpty() {
        let item: DiscoveredBinding = .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1),
                originModule: testModule
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("(no dependencies)"))
    }

    // MARK: - Keyed @Provides / @Inject

    @Test func providesWithoutKeyArgumentHasNilKeyIdentifier() {
        // Sanity-check the default — unkeyed `@Provides` produces a
        // binding with `keyIdentifier == nil`. Existing tests cover this
        // implicitly; making it explicit pins the contract.
        let source = """
            @Provides let logger: Logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].keyIdentifier == nil)
    }

    @Test func providesWithMemberAccessKeyExtractsCanonicalText() {
        // `@Provides(Database.primary)` — the canonical key is the
        // trimmed text of the argument expression. That's what other
        // bindings/consumers must match against.
        let source = """
            @Provides(Database.primary)
            let primaryDB: Database = Database()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].keyIdentifier == "Database.primary")
    }

    @Test func providesFunctionWithKeyExtractsCanonicalText() {
        // Same shape, but on a `@Provides func` — the key annotation
        // sits on the function declaration, not on individual params.
        let source = """
            @Provides(Database.primary)
            func makePrimaryDB() -> Database {
                Database()
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].keyIdentifier == "Database.primary")
    }

    @Test func injectPropertyWithKeyExtractsCanonicalText() {
        // `@Inject(Database.primary) var db: Database` — the consumer-
        // side annotation. Should propagate to the resulting
        // `DependencyParameter.keyIdentifier` so graph resolution can
        // match keyed slot.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject(Database.primary) var db: Database
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserRepo.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].keyIdentifier == "Database.primary")
    }

    @Test func injectInitParameterWithKeyExtractsCanonicalText() {
        // Per-parameter `@Inject(<key>)` on an `@Inject`-marked init.
        // The init-level `@Inject` (no args) marks the init as canonical;
        // per-parameter `@Inject(<key>)` keys that specific dep.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject
                init(@Inject(Database.primary) db: Database, logger: Logger) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserRepo.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 2)
        #expect(result[0].dependencies[0].name == "db")
        #expect(result[0].dependencies[0].keyIdentifier == "Database.primary")
        // Unkeyed dep stays unkeyed.
        #expect(result[0].dependencies[1].name == "logger")
        #expect(result[0].dependencies[1].keyIdentifier == nil)
    }

    @Test func providesFunctionParameterWithKeyExtractsCanonicalText() {
        // The same per-parameter `@Inject(<key>)` keying applies to
        // `@Provides func` parameters — they're deps just like
        // `@Inject` init parameters.
        let source = """
            @Provides
            func makeRepo(@Inject(Database.primary) db: Database, logger: Logger) -> Repository {
                Repository(db: db, logger: logger)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 2)
        #expect(result[0].dependencies[0].keyIdentifier == "Database.primary")
        #expect(result[0].dependencies[1].keyIdentifier == nil)
    }

    @Test func bareIdentifierKeyExtractsAsIs() {
        // File-scope key declarations (`let primary = BindingKey<Foo>()`)
        // referenced bare. Canonical key is just "primary". Cross-file
        // conflicts on bare keys get reported as duplicates by the
        // graph; that's the expected behavior.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject(primary) var db: Database
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserRepo.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies[0].keyIdentifier == "primary")
    }

    // MARK: - Warnings

    @Test func containerCombinedWithSingletonEmitsWarning() {
        // A type with both `@Container` and `@Singleton` ends up as
        // both a binding in the default graph and a grouping for its
        // own container — almost always a user error. Warn at the
        // type's name with a remedy suggestion.
        let source = """
            @Container
            @Singleton
            struct Mixed {
                @Inject var x: X
            }
            """
        let result = discover(in: source, sourcePath: "Mixed.swift", module: testModule)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@Container and @Singleton"))
        #expect(result.warnings[0].location.file == "Mixed.swift")
    }

    @Test func plainTypeDeclWithoutContainerEmitsNoWarning() {
        // Sanity check — a normal `@Singleton struct Foo` with no
        // `@Container` doesn't fire the warning.
        let source = """
            @Singleton
            struct Foo {
                @Inject var bar: Bar
            }
            """
        let result = discover(in: source, sourcePath: "Foo.swift", module: testModule)
        #expect(result.warnings.isEmpty)
    }

    @Test func injectInitInExtensionEmitsWarning() {
        // `@Inject` on an extension init is silently ignored by the
        // `@Singleton` macro (which only sees the primary declaration).
        // Warn at the init site with a fix-it suggestion.
        let source = """
            @Singleton
            struct Foo {
                @Inject var bar: Bar
            }

            extension Foo {
                @Inject init(custom: String) {
                }
            }
            """
        let result = discover(in: source, sourcePath: "Foo.swift", module: testModule)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@Inject on an extension init"))
        #expect(result.warnings[0].message.contains("'Foo'"))
    }

    @Test func unannotatedExtensionProvidesIsRecordedAsCandidate() {
        // The visitor records `@Provides` inside unannotated
        // extensions as candidate warnings — WireGen does the cross-
        // file resolution against the `@Container`-name set. This
        // test pins the candidate-collection step.
        let source = """
            extension AppConfig {
                @Provides static let logLevel: String = "info"
            }
            """
        let result = discover(in: source, sourcePath: "AppConfig.swift", module: testModule)
        #expect(result.unannotatedExtensionProvides.count == 1)
        let candidate = result.unannotatedExtensionProvides[0]
        #expect(candidate.extendedType == "AppConfig")
        #expect(candidate.providerName == "logLevel")
    }

    @Test func strayInjectOnNonScopeAnnotatedTypePropertyEmitsWarning() {
        // `Plain` isn't @Singleton/@RequestScope/@JobScope, so the
        // @Inject on a stored property is a silent no-op without the
        // warning. Surfacing it lets the user understand they need a
        // scope macro to get wiring.
        let source = """
            struct Plain {
                @Inject var logger: Logger
            }
            """
        let result = discover(in: source, sourcePath: "Plain.swift", module: testModule)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@Inject on 'logger' has no effect"))
        #expect(result.warnings[0].message.contains("'Plain'"))
    }

    @Test func strayInjectOnNonScopeAnnotatedTypeInitEmitsWarning() {
        // Same idea, init form. The user might think @Inject on the
        // init marks it as canonical, but without a scope macro on
        // the type there's no macro to read the marker.
        let source = """
            struct Plain {
                @Inject init(x: X) {
                }
            }
            """
        let result = discover(in: source, sourcePath: "Plain.swift", module: testModule)
        #expect(result.warnings.count == 1)
        #expect(
            result.warnings[0].message.contains(
                "@Inject on this initialiser has no effect"
            )
        )
    }

    @Test func injectOnSingletonTypeMemberDoesNotEmitWarning() {
        // Negative case — @Inject on a @Singleton's property IS
        // meaningful (read by the macro for init synthesis). No
        // warning. Pin the contract so a regression that over-warns
        // gets caught.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject var logger: Logger
            }
            """
        let result = discover(in: source, sourcePath: "UserRepo.swift", module: testModule)
        #expect(result.warnings.isEmpty)
    }

    @Test func strayInjectAtModuleScopeEmitsWarning() {
        // `@Inject let foo: Foo` at file scope is a no-op — there's
        // no enclosing type for the macro to read it from. Suggest
        // @Provides as the likely intent.
        let source = """
            @Inject let logger: Logger = Logger()
            """
        let result = discover(in: source, sourcePath: "Logger.swift", module: testModule)
        #expect(result.warnings.count == 1)
        #expect(
            result.warnings[0].message.contains(
                "@Inject on 'logger' at module scope has no effect"
            )
        )
        #expect(result.warnings[0].message.contains("use @Provides"))
    }

    @Test func injectOnProvidesFuncParameterDoesNotEmitWarning() {
        // `@Provides func make(@Inject(Key) x: X) -> T` uses
        // per-parameter @Inject for keyed disambiguation — meaningful,
        // not stray. The parameter @Inject is inside a func decl,
        // not a top-level var, so the module-scope check doesn't
        // fire either.
        let source = """
            @Provides
            func makeRepo(@Inject(.primary) db: Database) -> Repository {
                Repository(db: db)
            }
            """
        let result = discover(in: source, sourcePath: "Repos.swift", module: testModule)
        #expect(result.warnings.isEmpty)
    }

    @Test func containerAnnotatedExtensionProvidesIsNotACandidate() {
        // `@Container extension Foo { @Provides ... }` is the
        // user's explicit opt-in to contribute to Foo's container —
        // no warning. The candidate list stays empty for this case.
        let source = """
            @Container
            extension AppConfig {
                @Provides static let logLevel: String = "info"
            }
            """
        let result = discover(in: source, sourcePath: "AppConfig.swift", module: testModule)
        #expect(result.unannotatedExtensionProvides.isEmpty)
    }

    @Test func moduleScopeTypealiasIsCaptured() {
        let source = """
            typealias UserID = UUID
            """
        let result = discover(in: source, sourcePath: "Types.swift", module: testModule)
        #expect(result.typealiases.count == 1)
        #expect(result.typealiases[0].name == "UserID")
        #expect(result.typealiases[0].underlyingType == "UUID")
    }

    @Test func nestedTypealiasIsNotCaptured() {
        // Nested typealiases are deferred for the missing-binding
        // hint; only module-scope declarations are surfaced.
        let source = """
            enum Names {
                typealias UserID = UUID
            }
            """
        let result = discover(in: source, sourcePath: "Names.swift", module: testModule)
        #expect(result.typealiases.isEmpty)
    }

    @Test func genericTypealiasIsNotCaptured() {
        // Generic typealiases are deferred — substituting through
        // them at the missing-binding hint isn't designed yet.
        let source = """
            typealias Repo<T> = Repository<T>
            """
        let result = discover(in: source, sourcePath: "Repo.swift", module: testModule)
        #expect(result.typealiases.isEmpty)
    }

    @Test func declaredTypeNamesCapturesPrimaryDeclarations() {
        let source = """
            struct Alpha {}
            class Beta {}
            actor Gamma {}
            enum Delta {}
            protocol Epsilon {}
            """
        let result = discover(in: source, sourcePath: "Types.swift", module: testModule)
        #expect(Set(result.declaredTypeNames) == ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"])
    }

    @Test func declaredTypeNamesExcludesExtensionTargets() {
        // Extensions aren't primary declarations — `extension Foo`
        // doesn't *declare* Foo, it adds to whatever Foo is. The
        // cross-module-extension warning depends on this distinction.
        let source = """
            extension SomeImportedType {
                @Provides static let value: Int = 42
            }
            """
        let result = discover(in: source, sourcePath: "Ext.swift", module: testModule)
        #expect(result.declaredTypeNames.isEmpty)
    }

    @Test func crossModuleExtensionWarningFiresForUndeclaredType() {
        // `Logger` isn't declared in this module — the `@Provides` in
        // its extension probably wasn't meant to silently land in the
        // default graph.
        let source = """
            extension Logger {
                @Provides static let appLogger: Logger = Logger()
            }
            """
        let discovery = discover(in: source, sourcePath: "LoggerExt.swift", module: testModule)
        let warnings = crossModuleExtensionDiagnostics(
            candidates: discovery.unannotatedExtensionProvides,
            containerNames: [],
            declaredTypeNames: Set(discovery.declaredTypeNames)
        )
        #expect(warnings.count == 1)
        #expect(warnings[0].message.contains("'Logger' isn't declared in this module"))
    }

    @Test func crossModuleExtensionWarningSkipsLocallyDeclaredType() {
        // `LocalType` is declared in this same module, so an
        // extension on it with @Provides is fine — it lands in the
        // default graph the same as a primary-decl static @Provides
        // would.
        let source = """
            struct LocalType {}

            extension LocalType {
                @Provides static let value: Int = 42
            }
            """
        let discovery = discover(in: source, sourcePath: "Local.swift", module: testModule)
        let warnings = crossModuleExtensionDiagnostics(
            candidates: discovery.unannotatedExtensionProvides,
            containerNames: [],
            declaredTypeNames: Set(discovery.declaredTypeNames)
        )
        #expect(warnings.isEmpty)
    }

    @Test func crossModuleExtensionWarningDefersToContainerWarning() {
        // `AppConfig` is a @Container — the existing container-aware
        // warning handles this case; the cross-module helper stays
        // silent so we don't double-warn.
        let source = """
            @Container
            enum AppConfig {}

            extension AppConfig {
                @Provides static let logLevel: String = "info"
            }
            """
        let discovery = discover(in: source, sourcePath: "AppConfig.swift", module: testModule)
        let warnings = crossModuleExtensionDiagnostics(
            candidates: discovery.unannotatedExtensionProvides,
            containerNames: ["AppConfig"],
            declaredTypeNames: Set(discovery.declaredTypeNames)
        )
        #expect(warnings.isEmpty)
    }

    @Test func crossModuleExtensionWarningSkipsMemberTypeTargets() {
        // `Foo.Bar` resolves to the trimmedDescription form ("Foo.Bar")
        // since it isn't an IdentifierTypeSyntax. Without a real name
        // lookup we can't tell whether `Foo.Bar` refers to a local
        // type, so we err toward silence.
        let source = """
            extension Foo.Bar {
                @Provides static let value: Int = 42
            }
            """
        let discovery = discover(in: source, sourcePath: "Complex.swift", module: testModule)
        let warnings = crossModuleExtensionDiagnostics(
            candidates: discovery.unannotatedExtensionProvides,
            containerNames: [],
            declaredTypeNames: Set(discovery.declaredTypeNames)
        )
        #expect(warnings.isEmpty)
    }

    @Test func nonInjectExtensionInitIsRecordedAsCandidate() {
        // `init` inside an extension without `@Inject` — recorded as
        // a candidate; the per-extended-type check happens in
        // WireGen after aggregation.
        let source = """
            extension Foo {
                init(custom: String) {
                }
            }
            """
        let result = discover(in: source, sourcePath: "FooExt.swift", module: testModule)
        #expect(result.nonInjectExtensionInits.count == 1)
        #expect(result.nonInjectExtensionInits[0].extendedType == "Foo")
    }

    @Test func injectExtensionInitIsNotRecordedAsNonInjectCandidate() {
        // `@Inject init` in an extension is the OTHER warning's
        // territory; the non-Inject candidate list stays empty.
        let source = """
            extension Foo {
                @Inject init(custom: String) {
                }
            }
            """
        let result = discover(in: source, sourcePath: "FooExt.swift", module: testModule)
        #expect(result.nonInjectExtensionInits.isEmpty)
    }

    @Test func extensionInitConflictWarningFiresForSingletonType() {
        let candidate = NonInjectExtensionInit(
            extendedType: "Foo",
            location: SourceLocation(file: "FooExt.swift", line: 2, column: 5)
        )
        let warnings = extensionInitConflictDiagnostics(
            candidates: [candidate],
            singletonTypeNames: ["Foo"]
        )
        #expect(warnings.count == 1)
        #expect(warnings[0].message.contains("extension init conflicts"))
        #expect(warnings[0].message.contains("'Foo'"))
    }

    @Test func extensionInitConflictWarningSkipsNonSingletonType() {
        // Foo isn't @Singleton in this module — extension init is
        // just an additional init, no Wire-generated init to conflict
        // with. No warning.
        let candidate = NonInjectExtensionInit(
            extendedType: "Foo",
            location: SourceLocation(file: "FooExt.swift", line: 2, column: 5)
        )
        let warnings = extensionInitConflictDiagnostics(
            candidates: [candidate],
            singletonTypeNames: []
        )
        #expect(warnings.isEmpty)
    }

    @Test func crossModuleExtensionWarningTreatsGenericExtensionAsBaseName() {
        // `extension Array<Int>` parses as an IdentifierTypeSyntax
        // whose `.name.text` is `Array`; the generic argument clause
        // is a separate child. So the candidate's extendedType is
        // `Array`, the warning sees an unknown out-of-module name,
        // and fires. Pin the contract so a discovery change that
        // preserves the generic form (and would yield `Array<Int>`)
        // surfaces as a test failure rather than a silent behaviour
        // shift.
        let source = """
            extension Array<Int> {
                @Provides static let empty: [Int] = []
            }
            """
        let discovery = discover(in: source, sourcePath: "ArrayExt.swift", module: testModule)
        let warnings = crossModuleExtensionDiagnostics(
            candidates: discovery.unannotatedExtensionProvides,
            containerNames: [],
            declaredTypeNames: Set(discovery.declaredTypeNames)
        )
        #expect(warnings.count == 1)
        #expect(warnings[0].message.contains("'Array' isn't declared in this module"))
    }

    // MARK: - @Scoped(seed:) discovery + per-seed routing

    @Test func scopedTypeRoutedToPerSeedPartition() {
        let source = """
            @Scoped(seed: RequestSeed.self)
            struct RequestLogger {
            }
            """
        let result = discover(in: source, sourcePath: "RequestLogger.swift", module: testModule)
        // Scoped types DON'T appear in the default-graph slice...
        #expect(result.bindings.isEmpty)
        // ...they're routed into `allBindings` under a Partition
        // whose `scope` carries the seed.
        let partition = Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))
        #expect(result.allBindings[partition]?.count == 1)
        guard case .scopeBound(let scopeBound) = result.allBindings[partition]?.first else {
            Issue.record("Expected a singleton-shaped scoped binding")
            return
        }
        #expect(scopeBound.typeName == "RequestLogger")
        #expect(scopeBound.scopeKey?.seed == "RequestSeed")
        #expect(scopeBound.scopeKey?.within == nil)
    }

    @Test func twoScopedTypesSameSeedShareAPartition() {
        let source = """
            @Scoped(seed: RequestSeed.self)
            struct RequestLogger {
            }

            @Scoped(seed: RequestSeed.self)
            struct RequestMetrics {
            }
            """
        let result = discover(in: source, sourcePath: "Request.swift", module: testModule)
        let partition = Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))
        #expect(result.allBindings[partition]?.count == 2)
    }

    @Test func scopedTypesWithDifferentSeedsGetIndependentPartitions() {
        let source = """
            @Scoped(seed: RequestSeed.self)
            struct RequestLogger {
            }

            @Scoped(seed: SQSMessage.self)
            struct SQSWorker {
            }
            """
        let result = discover(in: source, sourcePath: "Mixed.swift", module: testModule)
        let requestPartition = Partition(container: nil, scope: ScopeKey(seed: "RequestSeed"))
        let sqsPartition = Partition(container: nil, scope: ScopeKey(seed: "SQSMessage"))
        #expect(result.allBindings[requestPartition]?.count == 1)
        #expect(result.allBindings[sqsPartition]?.count == 1)
        // The two partitions are distinct keys; the scopes don't mix.
        #expect(requestPartition != sqsPartition)
    }

    @Test func scopedSeedExpressionPreservesGenericArgs() {
        // The seed expression goes through verbatim — `Foo<Bar>` is
        // distinct from `Foo<Baz>`. The build plugin's canonical-type
        // normalisation (whitespace stripping) happens separately at
        // graph-identity time.
        let source = """
            @Scoped(seed: TenantSeed<String>.self)
            struct TenantCache {
            }
            """
        let result = discover(in: source, sourcePath: "TenantCache.swift", module: testModule)
        let partition = Partition(
            container: nil,
            scope: ScopeKey(seed: "TenantSeed<String>")
        )
        #expect(result.allBindings[partition]?.count == 1)
    }

    @Test func singletonAndScopedCoexistInSeparatePartitions() {
        let source = """
            @Singleton
            struct AppConfig {
            }

            @Scoped(seed: RequestSeed.self)
            struct RequestLogger {
            }
            """
        let result = discover(in: source, sourcePath: "App.swift", module: testModule)
        // @Singleton lands in the default partition (container nil,
        // scope nil); @Scoped lands in a per-seed partition. They
        // share the dictionary but stay separate keys.
        #expect(result.bindings.count == 1)
        let scopedPartition = Partition(
            container: nil,
            scope: ScopeKey(seed: "RequestSeed")
        )
        #expect(result.allBindings[scopedPartition]?.count == 1)
        if case .scopeBound(let scopeBound) = result.bindings.first {
            #expect(scopeBound.scopeKey == nil)
        } else {
            Issue.record("Expected AppConfig to be discovered as a default-graph singleton")
        }
    }

    @Test func scopedInsideContainerRoutesToContainerAndSeedPartition() {
        // Container × scope is orthogonal: a `@Scoped` inside a
        // `@Container` lands in a partition keyed by both
        // (container: "TestContainer", scope: seed). Tests can swap
        // request-scoped types by selecting the container.
        let source = """
            @Container
            enum TestContainer {
                @Scoped(seed: RequestSeed.self)
                struct TestRequestLogger {
                }
            }
            """
        let result = discover(in: source, sourcePath: "TestContainer.swift", module: testModule)
        let partition = Partition(
            container: "TestContainer",
            scope: ScopeKey(seed: "RequestSeed")
        )
        #expect(result.allBindings[partition]?.count == 1)
        // The default-graph slice and the test container's singleton
        // slice are both empty — the scoped binding isn't in either.
        #expect(result.bindings.isEmpty)
        #expect(result.containerBindings["TestContainer"]?.isEmpty ?? true)
    }

    @Test func containerWithScopedWarningFires() {
        // `@Container` plus `@Scoped` on the same type is as
        // problematic as `@Container` plus `@Singleton` — the type
        // ends up as both a node in one graph and a grouping for
        // another. Iteration-3's container-with-scope warning fires
        // for both since `scopeMacroNames` now contains "Scoped".
        let source = """
            @Container
            @Scoped(seed: RequestSeed.self)
            struct Mixed {
            }
            """
        let result = discover(in: source, sourcePath: "Mixed.swift", module: testModule)
        #expect(result.warnings.count == 1)
        #expect(
            result.warnings[0].message.contains(
                "'Mixed' carries both @Container and @Scoped"
            )
        )
    }

    // MARK: - allowUnused (dead-binding silencer)

    @Test func allowUnusedTrueIsCapturedOnSingleton() {
        let result = discoverSingletons(
            in: "@Singleton(allowUnused: true) struct A {}",
            sourcePath: "A.swift"
        )
        #expect(result.count == 1)
        #expect(result[0].allowUnused)
    }

    @Test func plainSingletonIsNotAllowUnused() {
        let result = discoverSingletons(in: "@Singleton struct A {}", sourcePath: "A.swift")
        #expect(!result[0].allowUnused)
    }

    @Test func allowUnusedTrueIsCapturedOnProvides() {
        let result = discoverProviders(
            in: "@Provides(allowUnused: true) let foo: Foo = Foo()",
            sourcePath: "F.swift"
        )
        #expect(result.count == 1)
        #expect(result[0].allowUnused)
        // The labelled `allowUnused:` argument must not be mistaken for a key.
        #expect(result[0].keyIdentifier == nil)
    }

    @Test func keyedProvidesWithAllowUnusedCapturesBoth() {
        let result = discoverProviders(
            in: "@Provides(Foo.primary, allowUnused: true) let foo: Foo = Foo()",
            sourcePath: "F.swift"
        )
        #expect(result[0].keyIdentifier == "Foo.primary")
        #expect(result[0].allowUnused)
    }
}
