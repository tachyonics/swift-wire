import Synchronization
import Wire

/// A minimal router controllers register with. A reference type so the
/// registration's mutation is visible on the bootstrapped graph's instance;
/// its mutable state is `Mutex`-guarded (the same pattern as `Wire.AtomicState`),
/// so it's properly `Sendable` and the synchronous `register` keeps
/// `_wireRegister` synchronous.
public final class Router: Sendable {
    private let recorded = Mutex<[String]>([])
    public init() {}

    public var routes: [String] { recorded.withLock { $0 } }

    /// Record a registered instance by its type name.
    public func register(_ instance: Any) {
        recorded.withLock { $0.append(String(describing: type(of: instance))) }
    }
}

/// `@RoutedBy(R.self)` — a type-level adapter annotation. The member macro
/// generates `_wireRegister(instance:router:)`; the definition below is what
/// Wire discovers to learn that registration's dependency signature.
@attached(member, names: named(_wireRegister))
public macro RoutedBy<R>(_ routerType: R.Type) =
    #externalMacro(module: "WireRoutingMacros", type: "RoutedByMacro")

/// The Wire-facing definition: `@RoutedBy` is a type-level adapter whose
/// `_wireRegister` takes the annotated instance and the annotation's first type
/// argument (the router). Discovered by re-parsing (M1) the same way a binding
/// key is — no specific filename required.
enum RoutingAdapter {
    static let routedBy = WireAdapterAnnotationV1(
        annotation: "RoutedBy",
        form: .typeLevel,
        registerSignature: "(instance: Self, router: $0)"
    )
}
