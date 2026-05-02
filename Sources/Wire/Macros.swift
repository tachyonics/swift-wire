// Public-facing macro declarations.
//
// At M1 only `@Singleton` and `@Inject` ship. `@RequestScope`, `@JobScope`,
// `@Container`, `@Provides`, `@Contributes` arrive in subsequent iterations.

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

/// Marks a stored property as an injection point. The enclosing type's
/// scope macro (`@Singleton`, `@RequestScope`, `@JobScope`) reads these
/// markers to synthesise its initialiser.
///
/// `@Inject` itself contributes no code — it's a marker that other macros
/// recognise. Putting `@Inject` on a property of a type that has no scope
/// macro is harmless but pointless.
@attached(peer)
public macro Inject() = #externalMacro(module: "WireMacrosImpl", type: "InjectMacro")
