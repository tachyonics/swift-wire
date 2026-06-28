import Wire

/// A `public @Singleton` published by an external Wire-aware library. The
/// consumer composes it across a package boundary; `public` (and a public
/// `@Inject init`) satisfies the cross-module visibility threshold (7f).
@Singleton
public struct ExternalService {
    public let name: String

    @Inject
    public init() {
        self.name = "external"
    }
}

extension ExternalService {
    /// A named key published by the library, referenced by the consumer
    /// across the package boundary — exercises cross-module key resolution
    /// (7a's tracking + 7f's "key in the parse set" widening).
    public static let primary = BindingKey<ExternalService>()
}

/// A second, keyed binding of `ExternalService` so the consumer can
/// `@Inject(ExternalService.primary)` across modules alongside the unkeyed
/// `@Singleton`.
@Provides(ExternalService.primary)
public func makePrimaryExternalService() -> ExternalService {
    ExternalService()
}
