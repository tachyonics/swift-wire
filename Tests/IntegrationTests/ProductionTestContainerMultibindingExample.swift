import Wire

/// The production/test-container pattern: a module-scope multibinding key
/// (a name, not owned by any container) contributed to from two different
/// containers, each providing its own services. Selecting a container at
/// the entry point selects its aggregate — the canonical reason containers
/// exist (the README's "swap the whole graph, typically for tests").
///
/// Proves keys are location-independent identities, consistent with
/// `BindingKey`: a container may contribute to a key declared outside it.

protocol AppService {
    func name() -> String
}

enum ServiceRegistry {
    static let all = CollectedKey<any AppService>()
}

@Container
enum ProdContainer {
    @Singleton @Contributes(to: ServiceRegistry.all)
    struct RealService: AppService {
        func name() -> String { "real" }
    }

    @Singleton(allowUnused: true)
    struct ServiceHost {
        @Inject(ServiceRegistry.all) var services: [any AppService]
    }
}

@Container
enum TestEnvContainer {
    @Singleton @Contributes(to: ServiceRegistry.all)
    struct MockService: AppService {
        func name() -> String { "mock" }
    }

    @Singleton(allowUnused: true)
    struct ServiceHost {
        @Inject(ServiceRegistry.all) var services: [any AppService]
    }
}
