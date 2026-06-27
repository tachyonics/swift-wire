import Wire

/// A public `@Singleton` published by a Wire-aware library, used by the
/// IntegrationTests target to exercise same-package cross-module
/// composition (iteration 7c). Because the consumer's generated
/// `_WireGraph` constructs this type, both the type and its `@Inject`
/// init are `public` — reachable across the module boundary. (The
/// build-time enforcement of that visibility threshold is iteration 7f;
/// here it's satisfied by hand.)
@Singleton
public struct LibraryService {
    public let name: String

    @Inject
    public init() {
        self.name = "library"
    }
}
