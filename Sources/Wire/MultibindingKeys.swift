// Multibinding key markers — the producer-side declarations that a
// `@Contributes(to:)` contribution and an aggregate `@Inject` consumer
// reference. Like `BindingKey<Value>`, these are phantom-typed: they
// carry no runtime state, and their identity in the graph is the
// *canonical text* of the declaring reference (`Application.middleware`),
// not any stored value. The generic parameters are what the
// `@Contributes` overload set uses to enforce flavour/argument validity
// at the type level (see `Macros.swift`), and what discovery reads to
// give an aggregate its element/value/result type (producer-side
// authority — see `Documentation/Notes/MultibindingsImplementationPlan.md`).

/// A list/set-style multibinding key. Contributors tagged
/// `@Contributes(to:)` against a `CollectedKey<Element>` are aggregated
/// into an ordered `[Element]`; the consumer injects that array.
///
///     extension App {
///         static let services = CollectedKey<any Service>()
///     }
///
///     @Singleton @Contributes(to: App.services)
///     struct AuthService: Service { ... }
///
///     @Inject(App.services) var services: [any Service]
///
/// `Element` is the array's element type, read producer-side from this
/// declaration. Contribution order is controlled by `withOrder:` on
/// `@Contributes`.
public struct CollectedKey<Element>: Sendable {
    public init() {}
}

/// A map-style multibinding key. Contributors tagged `@Contributes(to:,
/// atKey:)` against a `MappedKey<Key, Value>` are aggregated into a
/// `[Key: Value]`; the consumer injects that dictionary.
///
///     extension App {
///         static let strategies = MappedKey<String, any Strategy>()
///     }
///
///     @Singleton @Contributes(to: App.strategies, atKey: "fast")
///     struct FastStrategy: Strategy { ... }
///
///     @Inject(App.strategies) var strategies: [String: any Strategy]
///
/// `atKey:` is required on every contribution and is typed to `Key`, so
/// a wrong-typed key fails to compile. Duplicate keys are a compile-time
/// error raised by the build plugin (a duplicate-key dictionary literal
/// is a runtime trap, so it can't be left to the compiler).
public struct MappedKey<Key: Hashable, Value>: Sendable {
    public init() {}
}

/// A builder-style multibinding key. Contributors tagged
/// `@Contributes(to:)` against a `BuilderKey<Builder>` are folded through
/// the `@resultBuilder` type `Builder`; the consumer injects whatever the
/// builder produces. Unlike `CollectedKey`/`MappedKey`, which fix the
/// aggregation shape, `BuilderKey` lets the producer define *how*
/// contributors compose.
///
///     @resultBuilder
///     enum MiddlewareBuilder {
///         static func buildBlock(_ parts: any Middleware...) -> [any Middleware] {
///             Array(parts)
///         }
///     }
///
///     extension App {
///         static let middleware = BuilderKey<MiddlewareBuilder>()
///     }
///
/// The aggregate's type is the builder's `buildBlock` / `buildFinalResult`
/// return type, read producer-side. The parameterised-opaque case (a
/// type-varying fold consumed via `some P`) is deferred to
/// `OpaqueTypesSupport`; the fixed-result case ships in iteration 5β.
/// `withOrder:` on `@Contributes` sequences the fold's components.
public struct BuilderKey<Builder>: Sendable {
    public init() {}
}
