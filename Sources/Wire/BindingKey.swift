/// A typed identifier for a binding in the dependency graph.
///
/// Every `@Singleton`/`@RequestScope`/`@JobScope` macro auto-generates a
/// `static let key: BindingKey<Self>` on the type. Users only ever *read*
/// keys, and only when an ambiguity forces them to disambiguate at an
/// `@Inject` site. Named keys (declared explicitly to disambiguate
/// same-type-different-role bindings, e.g. `Database.primary` /
/// `Database.replica`) carry an `identifier` so two keys of the same
/// `Value` type can be distinguished.
public struct BindingKey<Value>: Sendable, Hashable {
    /// Optional name distinguishing two keys of the same `Value` type.
    /// `nil` means the default unnamed key for `Value`.
    public let identifier: String?

    public init(_ identifier: String? = nil) {
        self.identifier = identifier
    }
}
