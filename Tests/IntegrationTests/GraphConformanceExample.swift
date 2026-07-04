import Wire

// M2.1 end-to-end: a `WireGraphConformanceV1` makes the generated `_WireGraph`
// conform to an app-declared protocol, mapping a member to a `CollectedKey`'s
// product. The protocol's associated `Context` is inferred from the witness's
// element type — the load-bearing associated-type inference, exercised through the
// real build plugin (discover → aggregate → emit `extension _WireGraph: …`).

protocol RouteThing<Context> {
    associatedtype Context
    func label() -> String
}

struct RequestCtx {}

protocol GraphComposable {
    associatedtype Context
    var things: [any RouteThing<Context>] { get }
}

enum ThingKeys {
    // Consumed only by the generated conformance (nothing `@Inject`s it), so
    // `allowUnused` silences the empty-/dead-multibinding warning.
    static let things = CollectedKey<any RouteThing<RequestCtx>>(allowUnused: true)
}

@Singleton @Contributes(to: ThingKeys.things)
struct AlphaThing: RouteThing {
    typealias Context = RequestCtx
    func label() -> String { "alpha" }
}

@Singleton @Contributes(to: ThingKeys.things)
struct BetaThing: RouteThing {
    typealias Context = RequestCtx
    func label() -> String { "beta" }
}

enum GraphComposableConformance {
    static let decl = WireGraphConformanceV1(
        conformsTo: (any GraphComposable).self,
        members: [.init("things", from: ThingKeys.things)]
    )
}
