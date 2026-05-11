/// A typed marker identifying a binding in the dependency graph.
///
/// `BindingKey<Value>` is a phantom-typed marker. It carries no runtime
/// state; its job is to let users declare keys at the source level
/// (typically as static members on the bound type) and reference them
/// in `@Inject(...)` / `@Provides(...)` arguments. The build plugin
/// matches keyed bindings to keyed consumers by the *canonical text* of
/// the key expression — e.g. `Database.primary` — so what the user
/// writes IS the key.
///
/// Every `@Singleton`/`@RequestScope`/`@JobScope` macro auto-generates
/// a `static let key: BindingKey<Self>` on the type. Users add named
/// keys via additional static members:
///
///     extension Database {
///         static let primary = BindingKey<Database>()
///         static let replica = BindingKey<Database>()
///     }
///
/// And reference them at injection sites:
///
///     @Inject(Database.primary) var db: Database
///     @Provides(Database.primary) static let primaryDB: Database = ...
///
/// The generic parameter `Value` documents which type the key is
/// intended for. Swift's type system uses it at the call site to
/// rule out non-`BindingKey` arguments (`@Inject(42)` fails to
/// compile), and the build plugin's emitted type-assertion functions
/// unify it with the consuming binding's type to catch mismatches —
/// `@Inject(Database.primary) var db: Cache` doesn't type-check.
public struct BindingKey<Value>: Sendable {
    public init() {}
}
