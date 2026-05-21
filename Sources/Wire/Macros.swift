// Public-facing macro declarations.
//
// The currently shipping surface is `@Singleton`, `@Scoped`,
// `@Inject`, `@Provides`, and `@Container`. `@Contributes` is
// planned for a later milestone.

/// Declares a process-lifetime singleton. The macro generates:
/// - A `static let key: BindingKey<Self>` for the auto-generated key.
/// - An `init(...)` taking one parameter per `@Inject` property on the
///   type, in declaration order.
///
/// Apply to a struct or class (final preferred). Generic types are
/// supported and stay generic — type parameters propagate through the
/// generated init and key.
@attached(member, names: named(init), named(key))
public macro Singleton() = #externalMacro(module: "WireMacrosImpl", type: "SingletonMacro")

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
@attached(member, names: named(init), named(key))
public macro Scoped<Seed>(seed: Seed.Type) =
    #externalMacro(module: "WireMacrosImpl", type: "ScopedMacro")

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
public macro Provides() = #externalMacro(module: "WireMacrosImpl", type: "ProvidesMacro")

@attached(peer)
public macro Provides<Value>(_ key: BindingKey<Value>) =
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
