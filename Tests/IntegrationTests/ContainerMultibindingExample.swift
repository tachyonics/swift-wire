import Wire

/// End-to-end exercise of a multibinding *inside a `@Container`*. The key,
/// its contributors, and its consumer all live in the container, so the
/// aggregate is built atomically in the container's graph
/// (`_PluginContainerWireGraph`) from the container's own contributors —
/// not the default graph's.

protocol ContainerPlugin {
    func id() -> String
}

@Container
enum PluginContainer {
    static let plugins = CollectedKey<any ContainerPlugin>()

    @Singleton @Contributes(to: PluginContainer.plugins, withOrder: 1)
    struct AlphaPlugin: ContainerPlugin {
        func id() -> String { "alpha" }
    }

    @Singleton @Contributes(to: PluginContainer.plugins, withOrder: 2)
    struct BetaPlugin: ContainerPlugin {
        func id() -> String { "beta" }
    }

    @Singleton(allowUnused: true)
    struct PluginConsumer {
        @Inject(PluginContainer.plugins) var plugins: [any ContainerPlugin]
    }
}
