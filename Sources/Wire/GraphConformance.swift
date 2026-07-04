// Public carrier for a graph-conformance declaration.
//
// An adapter package declares one of these to have Wire emit a conformance of the
// generated graph to `protocolType`, mapping each of the protocol's members to the
// product of a multibinding key. Wire discovers the declaration syntactically
// (like a `BindingKey` / `WireAdapterAnnotationV1` declaration) and never executes
// it — so the stored values here are only what's useful for debugging; the
// protocol and key references are read from source.
//
//     enum HummingbirdComposition {
//         static let conformance = WireGraphConformanceV1(
//             conformsTo: (any HummingbirdComposable).self,
//             members: [
//                 .init("routes", from: HummingbirdKeys.routes),        // a CollectedKey
//                 .init("middleware", from: HummingbirdKeys.middleware) // a BuilderKey
//             ]
//         )
//     }
//
// Wire emits `extension _WireGraph: HummingbirdComposable { var routes { … } … }`,
// mapping each member to the aggregate binding for its key. It infers the
// protocol's associated types from the witnesses (e.g. a `Context` associated type
// from a `CollectedKey<any RouteContributor<Context>>` element type) — Wire itself
// knows nothing about what the protocol means.
//
// Versioned by type: a change to the contract shape ships a new
// `WireGraphConformanceV2`, leaving adapters written against V1 working. The build
// plugin recognises each version by its type name.
public struct WireGraphConformanceV1: Sendable {
    /// One member mapping: a protocol requirement name and the multibinding key
    /// whose product witnesses it.
    public struct Member: Sendable {
        /// The protocol member's name — e.g. `"routes"`.
        public let name: String

        /// - Parameters:
        ///   - name: the protocol member's name.
        ///   - key: the multibinding key whose product witnesses the member —
        ///     the same key reference a `@Contributes(to:)` uses (read from source
        ///     by canonical text, not executed).
        public init(_ name: String, from key: Any) {
            self.name = name
        }
    }

    public let members: [Member]

    /// - Parameters:
    ///   - protocolType: the protocol the generated graph should conform to —
    ///     `(any P).self` (read from source, not executed).
    ///   - members: the member-to-key mappings.
    public init(conformsTo protocolType: Any.Type, members: [Member]) {
        self.members = members
    }
}
