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

    @Test func defaultModuleIsNil() {
        // discover() without a module (the common unit-test path) leaves
        // origin unstamped — the single-module "own module" default.
        let source = """
            @Singleton
            struct A {
                @Inject init() {}
            }
            """
        let bindings = discover(in: source, sourcePath: "A.swift").bindings
        #expect(bindings.first?.originModule == nil)
    }

    @Test func settingOriginModuleStampsEachBindingKind() {
        let scopeBound = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("A.swift")
            )
        )
        let provider = DiscoveredBinding.provider(
            DiscoveredProvider(
                boundType: "B",
                accessPath: "makeB",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("B.swift")
            )
        )
        #expect(scopeBound.settingOriginModule("M").originModule == "M")
        #expect(provider.settingOriginModule("M").originModule == "M")
        // Re-stamping overwrites (composition re-stamps dependency sources).
        #expect(scopeBound.settingOriginModule("M").settingOriginModule("N").originModule == "N")
    }
}
