// Public-facing macro declarations.
//
// The currently shipping surface is `@Singleton`, `@Scoped`,
// `@Inject`, `@Provides`, `@Container`, `@Contributes`,
// `@Teardown`, and `@Replaces`.

/// Declares a process-lifetime singleton. The macro generates:
/// - A `static let key: BindingKey<Self>` for the auto-generated key.
/// - An `init(...)` taking one parameter per `@Inject` property on the
///   type, in declaration order.
///
/// Apply to a struct or class (final preferred). Generic types are
/// supported and stay generic — type parameters propagate through the
/// generated init and key.
@attached(member, names: named(init), named(key))
public macro Singleton(allowUnused: Bool = false) =
    #externalMacro(module: "WireMacrosImpl", type: "SingletonMacro")

/// Declares a process-lifetime singleton whose *graph identity* is the opaque
/// type `some P`, not its concrete type — so abstract consumers resolve it as
/// `some P` while the concrete type is still what Wire constructs. Use to expose
/// a self-producer behind a protocol so the dependency chain stays `some`
/// end-to-end and the concrete type is named once at the leaf, instead of
/// spelling the full nested specialisation at a composition root. The generated
/// members are identical to `@Singleton`; the `as:` argument only sets identity.
/// See `OpaqueTypesSupport.md`.
@attached(member, names: named(init), named(key))
public macro Singleton<T>(as: T.Type, allowUnused: Bool = false) =
    #externalMacro(module: "WireMacrosImpl", type: "SingletonMacro")

/// Declares a type that lives for the dynamic extent of a scope keyed
/// by `seed`. The seed type uniquely identifies the scope — two
/// `@Scoped(seed: X.self)` types share a scope iff `X` is the same
/// type. Bindings in the scope (including the seed value itself) are
/// available to any `@Scoped(seed: X.self)` type inside it; the seed
/// is implicitly bound when the scope is entered via
/// `withScope(seeding:body:)`.
///
/// The macro generates the same members as `@Singleton`: an `init(...)`
/// from `@Inject`-marked properties (or the user's `@Inject`-marked
/// init), and a `static var key: BindingKey<Self>`. Scope identity
/// (which graph partition the binding belongs to) is read by the
/// build plugin from the `seed:` argument; it doesn't enter the
/// generated members.
///
/// Apply to a struct, class, or actor. Generic types are supported.
///
/// `@Singleton` is the special case for process-lifetime values that
/// have no seed.
///
/// **Scope block (on a namespace `enum`).** Applied to a caseless enum,
/// `@Scoped(seed: X.self)` *defines* the scope for the `@Provides`
/// declarations inside it — the scope-axis sibling of `@Container`. Every
/// `@Provides` in the block is routed into the `X`-seed scope without
/// repeating the seed on each one:
///
///     @Scoped(seed: RequestSeed.self)
///     enum RequestProviders {
///         @Provides static func makeContext(seed: RequestSeed) -> Context { ... }
///         @Provides static let tag: Tag = Tag()
///     }
///
/// On an enum the macro synthesises nothing (it's a marker the build
/// plugin reads); on a struct/class/actor it synthesises `init`/`key` as
/// above. `@Singleton` self-producers can't live in a scope block (their
/// lifetime is the process, not the scope) — the plugin diagnoses that.
@attached(member, names: named(init), named(key))
public macro Scoped<Seed>(seed: Seed.Type, allowUnused: Bool = false) =
    #externalMacro(module: "WireMacrosImpl", type: "ScopedMacro")

/// Declares a generic type as a factory *template*, identified by a
/// `FactoryKey`. A factory template is to a factory what `@Singleton` is
/// to a singleton — it makes the type a Wire component and reads its
/// `@Inject` members as construction dependencies — but on two axes it
/// differs:
///
/// - The type's **generic parameters are assisted parameters**, supplied
///   per use-site (as metatypes) at the synthesised factory's `create`
///   call, not resolved from the graph.
/// - It is **not a binding of its own**. The build plugin synthesises one
///   concrete factory per `FactoryKey` its consumers demand, resolving the
///   template's `@Inject` deps once and injecting the factory where it's
///   consumed.
///
///     extension MyMiddleware {
///         static let session = FactoryKey()
///     }
///
///     @Factory(MyMiddleware.session)
///     struct SessionMiddleware<Ctx, Reader, Sender>: Middleware where … {
///         @Inject var store: SessionStore
///     }
///
/// The macro generates only the initialiser the synthesised factory calls
/// (from `@Inject` members, following the same rules as `@Singleton`); no
/// `static key` — the key is the `FactoryKey` argument. See
/// [`FactoryKey`](FactoryKey) and `AdapterModel.md`'s
/// `.injectsFactoryOnArgument` capability for the consumer side.
@attached(member, names: named(init))
public macro Factory(_ key: FactoryKey) =
    #externalMacro(module: "WireMacrosImpl", type: "FactoryMacro")

/// Marks a stored property (or init parameter) as an injection point.
/// The enclosing type's scope macro (`@Singleton` or `@Scoped`) reads
/// these markers to synthesise its initialiser, and the build plugin
/// reads them when discovering dependencies.
///
/// `@Inject` itself contributes no code — it's a marker that other
/// macros and the build plugin recognise. Putting `@Inject` on a
/// property of a type that has no scope macro is harmless but pointless.
///
/// Pass a `BindingKey<Value>` to disambiguate when multiple bindings of
/// the same type exist:
///
///     @Inject(Database.primary) var db: Database
///
/// The build plugin matches keyed consumers to keyed providers by the
/// *canonical text* of the key expression (`Database.primary` here).
/// Unkeyed `@Inject` matches only unkeyed bindings; keyed `@Inject`
/// matches only same-key bindings.
@attached(peer)
public macro Inject() = #externalMacro(module: "WireMacrosImpl", type: "InjectMacro")

@attached(peer)
public macro Inject<Value>(_ key: BindingKey<Value>) =
    #externalMacro(module: "WireMacrosImpl", type: "InjectMacro")

/// Inject a multibinding aggregate. Pass the `CollectedKey`/`MappedKey`/
/// `BuilderKey` the contributors target; the property's type is the
/// aggregated shape — `[Element]`, `[Key: Value]`, or the builder's
/// result type respectively.
///
///     @Inject(App.services) var services: [any Service]
@attached(peer)
public macro Inject<Element>(_ key: CollectedKey<Element>) =
    #externalMacro(module: "WireMacrosImpl", type: "InjectMacro")

@attached(peer)
public macro Inject<Key, Value>(_ key: MappedKey<Key, Value>) =
    #externalMacro(module: "WireMacrosImpl", type: "InjectMacro")

@attached(peer)
public macro Inject<Builder>(_ key: BuilderKey<Builder>) =
    #externalMacro(module: "WireMacrosImpl", type: "InjectMacro")

/// Declares a binding for the dependency graph at module scope or as a
/// `static` member of a non-`@Container` enclosing type. Attach to a
/// property (the binding has no dependencies) or a function (the
/// function's parameters become its dependencies).
///
/// Use `@Provides` for things the graph can't construct on its own —
/// framework primitives (loggers, configuration), values produced by
/// external systems, or concrete instances pinning a generic
/// constraint. Every `@Singleton` type is automatically part of the
/// graph and doesn't need a separate `@Provides`.
///
/// `@Provides` itself contributes no code — it's a marker the build
/// plugin recognises during source scanning.
///
/// Pass a `BindingKey<Value>` to declare a keyed binding when the same
/// type is bound multiple times:
///
///     @Provides(Database.primary) static let primaryDB: Database = ...
///     @Provides(Database.replica) static let replicaDB: Database = ...
///
/// Consumers reference the same key at the `@Inject` site to select
/// which binding to inject.
@attached(peer)
public macro Provides(allowUnused: Bool = false) =
    #externalMacro(module: "WireMacrosImpl", type: "ProvidesMacro")

@attached(peer)
public macro Provides<Value>(_ key: BindingKey<Value>, allowUnused: Bool = false) =
    #externalMacro(module: "WireMacrosImpl", type: "ProvidesMacro")

/// Declares a type (or an extension) as a selectable container.
/// `@Provides` declarations and nested `@Singleton` types inside the
/// annotated declaration become part of a separate graph that the
/// consumer can bootstrap by name — useful for swapping the entire
/// wired graph at the entry point (typically for tests).
///
/// Selection is atomic: a container's bindings *are* the graph for
/// that run — module-scope `@Provides` and module-scope `@Singleton`s
/// do not leak in. The build plugin generates an
/// `_<ContainerName>WireGraph` struct alongside the default
/// `_WireGraph`; the consumer picks one at the entry point.
///
/// `@Container` works on any type kind that can carry `static`
/// members (struct, class, enum, actor) and on extensions of any
/// type. The README's canonical pattern uses caseless enums for the
/// "namespace" feel, but the attribute is uniform across kinds. All
/// `@Container`-annotated declarations targeting the same type name
/// (e.g. `@Container enum Foo` plus `@Container extension Foo`)
/// merge their bindings into one logical container called `Foo`. A
/// plain `extension Foo { ... }` *without* the `@Container`
/// annotation does not contribute to the container; its bindings
/// fall through to the default graph. Cross-type composition
/// (multiple unrelated types contributing to one container) is a
/// future feature pending the `ContainerKey` design.
///
/// Combining `@Container` with `@Singleton` (or other scope macros)
/// on the same type is technically valid but conceptually unusual —
/// the type ends up as both a node in one graph and a grouping for
/// another. Iteration 3's diagnostic gallery will flag this case.
///
/// `@Container` itself contributes no code — it's a marker the build
/// plugin recognises during source scanning.
@attached(peer)
public macro Container() = #externalMacro(module: "WireMacrosImpl", type: "ContainerMacro")

/// Declares the annotated binding as a *contributor* to a multibinding
/// key — a `CollectedKey<Element>`, `MappedKey<Key, Value>`, or
/// `BuilderKey<Builder>`. The contributor keeps its own binding identity
/// (it stays independently `@Inject`-able) and additionally fans into the
/// aggregate the key names.
///
///     @Singleton @Contributes(to: App.services)
///     struct AuthService: Service { ... }
///
/// `@Contributes` itself contributes no code — it's a marker the build
/// plugin recognises during source scanning. It requires a co-located
/// producer macro (`@Singleton`/`@Scoped`/`@Provides`) to give the
/// contributor a lifetime.
///
/// The typed `to:` parameter does double duty: it's how the plugin learns
/// which key the contribution targets, and its overloads enforce
/// flavour/argument validity at compile time — `atKey:` is required on
/// `MappedKey` and rejected elsewhere, `withOrder:` is valid only on
/// `CollectedKey`/`BuilderKey`, and `atKey:` is typed to the map's `Key`.
@attached(peer)
public macro Contributes<Element>(to: CollectedKey<Element>) =
    #externalMacro(module: "WireMacrosImpl", type: "ContributesMacro")

/// Ordered contribution to a `CollectedKey<Element>`. `withOrder:` ranks
/// this contributor among the key's others; if any contributor on a key
/// specifies an order, all must (the no-mixing rule the build plugin
/// enforces).
@attached(peer)
public macro Contributes<Element>(to: CollectedKey<Element>, withOrder: Int) =
    #externalMacro(module: "WireMacrosImpl", type: "ContributesMacro")

/// Keyed contribution to a `MappedKey<Key, Value>`. `atKey:` is the map
/// entry's key and is typed to `Key`. Duplicate keys across a map's
/// contributors are a compile-time error raised by the build plugin.
@attached(peer)
public macro Contributes<Key: Hashable, Value>(to: MappedKey<Key, Value>, atKey: Key) =
    #externalMacro(module: "WireMacrosImpl", type: "ContributesMacro")

/// Contribution to a `BuilderKey<Builder>`. The contributor becomes one
/// component folded through the builder.
@attached(peer)
public macro Contributes<Builder>(to: BuilderKey<Builder>) =
    #externalMacro(module: "WireMacrosImpl", type: "ContributesMacro")

/// Ordered contribution to a `BuilderKey<Builder>`. `withOrder:`
/// sequences this contributor among the fold's components — often
/// type-relevant for order-sensitive builders like middleware chains.
@attached(peer)
public macro Contributes<Builder>(to: BuilderKey<Builder>, withOrder: Int) =
    #externalMacro(module: "WireMacrosImpl", type: "ContributesMacro")

/// Marks a binding's teardown action, so the scope's teardown phase can
/// run it in reverse dependency order.
///
/// **Owned-type member form** — no argument; marks the teardown method
/// on a `@Singleton`/`@Scoped` type. The method may be named anything,
/// takes no parameters, and must be at least `internal` — Wire's
/// generated bootstrap calls it at scope teardown from a separate file
/// (the same post-construct visibility rule as `@Inject func`). Its
/// effect specifiers (`async`/`throws`) are read off the declaration.
///
///     @Singleton
///     struct DatabasePool {
///         @Inject init(url: String) async throws { ... }
///
///         @Teardown
///         func teardown() async throws { try await client.shutdown() }
///     }
///
/// **Producer form** — on a `@Provides` declaration, carries the action
/// for the value the producer returns. The produced type stays honest
/// (no wrapper, no unwrap); consumers inject it directly. The action is
/// an explicit-typed closure or a reference to a free/static function; a
/// sync, non-throwing action coerces into the `async throws` contract.
/// Note Swift attributes take no trailing-closure sugar, so the closure
/// is parenthesised and its parameter is explicitly typed.
///
///     @Provides
///     @Teardown({ (client: HTTPClient) in try await client.shutdown() })
///     static func httpClient() -> HTTPClient { HTTPClient() }
///
/// `@Teardown` itself contributes no code — it's a marker the build
/// plugin recognises during source scanning. In M1 the plugin records
/// the action but emits no teardown calls; the reverse-dependency walk
/// lands in M4.
@attached(peer)
public macro Teardown() = #externalMacro(module: "WireMacrosImpl", type: "TeardownMacro")

@attached(peer)
public macro Teardown<Value>(_ action: @Sendable (Value) async throws -> Void) =
    #externalMacro(module: "WireMacrosImpl", type: "TeardownMacro")

/// Marks a binding as *superseding* the slot it already produces — the DI
/// test-double / override primitive (the analog of Hilt's `@BindValue` /
/// Spring's `@MockBean`). Attach it alongside a producer macro
/// (`@Singleton(as:)` / `@Provides`); the slot it supersedes is the one that
/// producer declares, so `@Replaces` takes no argument:
///
///     @Singleton(as: Repo.self)
///     @Replaces
///     struct FakeRepo: Repo { ... }
///
///     @Provides
///     @Replaces
///     static func fakeClient() -> SQSClient { ... }
///
/// A keyed producer supersedes its keyed slot for free — the key is part of
/// the binding's own identity, so `@Provides(Repo.primary) @Replaces` targets
/// the `Repo`/`primary` slot and `@Provides @Replaces` the unkeyed one; neither
/// crosses into the other's slot:
///
///     @Provides(Repo.primary) @Replaces
///     static let fakePrimary: Repo = FakeRepo()
///
/// When another binding — typically one composed in from a dependency
/// module — also produces that slot, the `@Replaces` binding wins and the
/// other is dropped from the graph, instead of the duplicate-binding error
/// two ordinary bindings for one slot would raise. The motivating use case:
/// a test target that composes an app's real bindings and substitutes a
/// fake for one dependency.
///
/// `@Replaces` itself contributes no code — it's a marker the build plugin
/// recognises during source scanning. There must be another binding for the
/// slot to supersede, and at most one `@Replaces` may target a given slot per
/// graph — the build plugin diagnoses each violation. The replaced binding
/// must live in a different module: two same-module bindings for one slot are
/// a plain duplicate, resolved directly rather than overridden.
@attached(peer)
public macro Replaces() =
    #externalMacro(module: "WireMacrosImpl", type: "ReplacesMacro")
