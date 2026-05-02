/// Read-only access to the resolved dependency graph.
///
/// Adapter `_wireRegister` functions take their dependencies as direct
/// parameters and almost never need a resolver. The resolver surfaces in
/// two cases:
///
/// 1. `Provider<T>` resolving lazily into a request scope (M4 onward).
/// 2. Explicit escape-hatch resolution by user code that has a real reason
///    to look up bindings dynamically.
///
/// At M1 the protocol is defined and the build-plugin-generated bootstrap
/// will eventually conform to it; the conformance is exercised when M2's
/// `WireHummingbird` adapter and M4's lifecycle orchestration land.
public protocol Resolver: Sendable {
    /// Resolve a binding by its value type. Equivalent to looking up the
    /// type's auto-generated `BindingKey<T>` (no identifier).
    func resolve<T>(_ type: T.Type) async throws -> T where T: Sendable

    /// Resolve a binding by an explicit key. Used when a named key
    /// disambiguates between bindings of the same value type.
    func resolve<T>(_ key: BindingKey<T>) async throws -> T where T: Sendable
}
