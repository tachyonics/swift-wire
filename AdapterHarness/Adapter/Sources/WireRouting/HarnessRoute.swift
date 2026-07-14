import Wire

/// A controller collated via the `@HarnessRoute` contribution alias.
public protocol Controller: Sendable {}

/// The collation key `@HarnessRoute` controllers contribute to.
public enum RoutingKeys {
    public static let controllers = CollectedKey<any Controller>()
}

/// `@HarnessRoute` — a type-level adapter annotation. The extension macro adds the
/// `Controller` conformance; the definition below is what Wire discovers to learn
/// the attribute aliases `@Contributes(to: RoutingKeys.controllers)`.
@attached(extension, conformances: Controller)
public macro HarnessRoute() =
    #externalMacro(module: "WireRoutingMacros", type: "HarnessRouteMacro")

/// The Wire-facing definition: `@HarnessRoute` on a binding aliases
/// `@Contributes(to: RoutingKeys.controllers)`. Discovered by re-parsing the same
/// way a binding key is — no specific filename required.
enum RoutingAdapter {
    static let harnessRoute = WireAdapterAnnotationV1(
        annotation: "HarnessRoute",
        capability: .contributes(to: RoutingKeys.controllers)
    )
}
