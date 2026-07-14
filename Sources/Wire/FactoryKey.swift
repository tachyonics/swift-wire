/// A namespace identifier for a `@Factory` template binding.
///
/// `FactoryKey` joins Wire's key family (`BindingKey<Value>` / `CollectedKey` /
/// `MappedKey` / `BuilderKey`), but unlike those it is **not** typed to a
/// produced value. A `@Factory` template is generic — the value it produces
/// varies per consumer — so no single `Value` could be fixed. It is a pure
/// *namespace token*: its identity in the graph is the *canonical text* of its
/// declaring reference (`MyMiddleware.session`), from which the build plugin
/// derives the synthesised factory's type name (`_WireFactory_session`).
///
/// Declare one as a static member alongside the template, and reference it from
/// both the template and its consumers:
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
///     @Middleware(MyMiddleware.session)          // consumer drives synthesis
///     struct AccountController { … }
///
/// The template's generic parameters are the *assisted* parameters — supplied
/// per use-site at the synthesised factory's `create` call, as metatypes; its
/// `@Inject` members are the injected dependencies, resolved once from the
/// graph. Because the key carries no value type, its build-time check is a
/// lighter namespace match than a `BindingKey`'s type unification; the real
/// type safety lands at the `create` call, where the compiler unifies the
/// assisted metatypes against the template's generic signature.
public struct FactoryKey: Sendable {
    public init() {}
}
