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

// A second composable whose key has *no* contributors. The generated conformance still
// holds — the member maps to an empty collection — so an adapter's protocol conforms
// even when this graph contributes nothing (the case where a consumer depends on an
// adapter for a utility, not its routes/services). Exercises the empty-accessor path.
protocol EmptyComposable {
    var emptyThings: [any RouteThing<RequestCtx>] { get }
}

enum EmptyKeys {
    static let things = CollectedKey<any RouteThing<RequestCtx>>()
}

enum EmptyComposableConformance {
    static let decl = WireGraphConformanceV1(
        conformsTo: (any EmptyComposable).self,
        members: [.init("emptyThings", from: EmptyKeys.things)]
    )
}
