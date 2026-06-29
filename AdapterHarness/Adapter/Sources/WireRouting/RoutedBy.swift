import Wire

/// A minimal router controllers register with. A reference type so the
/// registration's mutation is visible on the bootstrapped graph's instance.
public final class Router: @unchecked Sendable {
    public private(set) var routes: [String] = []
    public init() {}

    /// Record a registered instance by its type name.
    public func register(_ instance: Any) {
        routes.append(String(describing: type(of: instance)))
    }
}

/// `@RoutedBy(R.self)` — a type-level adapter annotation. The member macro
/// generates `_wireRegister(instance:router:)`; the definition below is what
/// Wire discovers to learn that registration's dependency signature.
@attached(member, names: named(_wireRegister))
public macro RoutedBy<R>(_ routerType: R.Type) =
    #externalMacro(module: "WireRoutingMacros", type: "RoutedByMacro")

/// The Wire-facing definition: `@RoutedBy` is a type-level, post-graph adapter
/// whose `_wireRegister` takes the annotated instance and the annotation's
/// first type argument (the router). Discovered by re-parsing (M1) the same way
/// a binding key is — no specific filename required.
enum RoutingAdapter {
    static let routedBy = WireAdapterAnnotationV1(
        annotation: "RoutedBy",
        form: .typeLevel,
        phase: .postGraph,
        registerSignature: "(instance: Self, router: $0)"
    )
}
