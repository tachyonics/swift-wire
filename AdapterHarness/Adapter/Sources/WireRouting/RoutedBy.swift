import Wire

/// A controller collated via the `@RoutedBy` contribution alias.
public protocol Controller: Sendable {}

/// The collation key `@RoutedBy` controllers contribute to.
public enum RoutingKeys {
    public static let controllers = CollectedKey<any Controller>()
}

/// `@RoutedBy` — a type-level adapter annotation. The extension macro adds the
/// `Controller` conformance; the definition below is what Wire discovers to learn
/// the attribute aliases `@Contributes(to: RoutingKeys.controllers)`.
@attached(extension, conformances: Controller)
public macro RoutedBy() =
    #externalMacro(module: "WireRoutingMacros", type: "RoutedByMacro")

/// The Wire-facing definition: `@RoutedBy` on a binding aliases
/// `@Contributes(to: RoutingKeys.controllers)`. Discovered by re-parsing (M1) the
/// same way a binding key is — no specific filename required.
enum RoutingAdapter {
    static let routedBy = WireAdapterAnnotationV1(
        annotation: "RoutedBy",
        contributesTo: RoutingKeys.controllers
    )
}
