import Testing

@testable import WireGenCore

/// Iteration 7b: origin-module metadata. Discovery stamps every binding
/// and key with the module its source belongs to (the consumer target
/// name, passed by the build plugin). The value is unused single-module
/// but load-bearing for SE-0491 qualification and the cross-module
/// visibility threshold under composition (7f).
@Suite("Origin module discovery")
struct OriginModuleDiscoveryTests {
    @Test func singletonCarriesOriginModule() {
        let source = """
            @Singleton
            struct A {
                @Inject init() {}
            }
            """
        let bindings = discover(in: source, sourcePath: "A.swift", module: "MyModule").bindings
        #expect(bindings.first?.originModule == "MyModule")
    }

    @Test func providerCarriesOriginModule() {
        let source = """
            @Provides
            let logger: Logger = Logger()
            """
        let bindings = discover(in: source, sourcePath: "L.swift", module: "MyModule").bindings
        #expect(bindings.first?.originModule == "MyModule")
    }

    @Test func scopedBindingCarriesOriginModule() {
        let source = """
            @Scoped(seed: RequestSeed.self)
            struct Tx {
                @Inject init() {}
            }
            """
        let scoped = discover(in: source, sourcePath: "T.swift", module: "MyModule")
            .allBindings.values.flatMap { $0 }
        #expect(scoped.first?.originModule == "MyModule")
    }

    @Test func bindingKeyCarriesOriginModule() {
        let source = """
            extension Database {
                static let primary = BindingKey<Database>()
            }
            """
        let keys = discover(in: source, sourcePath: "K.swift", module: "MyModule").bindingKeys
        #expect(keys.first?.originModule == "MyModule")
    }

    @Test func multibindingKeyCarriesOriginModule() {
        let source = """
            extension App {
                static let services = CollectedKey<any Service>()
            }
            """
        let keys = discover(in: source, sourcePath: "K.swift", module: "MyModule").multibindingKeys
        #expect(keys.first?.originModule == "MyModule")
    }

    @Test func distinctModulesStampDistinctly() {
        // Two discovery passes with different module names stamp their
        // bindings independently — the seam 7c uses when it reads each
        // dependency target's sources under its own module name.
        let source = """
            @Singleton
            struct A {
                @Inject init() {}
            }
            """
        let consumer = discover(in: source, sourcePath: "A.swift", module: "Consumer").bindings
        let library = discover(in: source, sourcePath: "A.swift", module: "Library").bindings
        #expect(consumer.first?.originModule == "Consumer")
        #expect(library.first?.originModule == "Library")
    }

    @Test func bindingAccessorReflectsConstructionModule() {
        // The enum-level accessor reads the module set at construction —
        // origin is non-optional and set once, not stamped after the fact.
        let binding = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("A.swift"),
                originModule: "Library"
            )
        )
        #expect(binding.originModule == "Library")
    }
}
