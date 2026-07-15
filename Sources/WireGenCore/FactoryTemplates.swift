// Factory-template discovery — the producer side of the factory model.
//
// A `@Factory(key)` type is a factory *template*: a generic Wire component
// whose generic parameters are assisted (supplied per use-site as metatypes)
// and whose `@Inject` members are injected dependencies. It is not a binding of
// its own; the plugin synthesises one concrete factory per `FactoryKey` its
// consumers demand (`@Middleware(key)` → the `.injectsFactoryOnArgument`
// capability). Discovery captures the template here — verbatim, syntactically —
// exactly as `DiscoveredScopeBoundType` captures a `@Singleton`. Synthesis and
// injection are later passes.

/// One `@Factory(key)`-annotated type found in a source file, with its key
/// reference, generic (assisted) parameters, and `@Inject` (injected)
/// dependencies extracted the same way a `@Singleton`'s are.
///
/// `keyReference` is the *canonical text* of the `@Factory` argument
/// (`MyMiddleware.session`) — the namespace identifier consumers reference and
/// the plugin derives the synthesised factory type name from. `typeName` is the
/// simple template name (`SessionMiddleware`); `qualifiedTypeName` prefixes any
/// enclosing types', since the synthesised factory's construction call lives at
/// module scope.
package struct DiscoveredFactoryTemplate: Sendable {
    package let keyReference: String
    package let typeName: String
    package let qualifiedTypeName: String
    package let typeKind: String
    /// The template's assisted parameters — the generic parameter names,
    /// supplied per use-site at the synthesised factory's `create` call.
    package let genericParameterNames: [String]
    /// Per-parameter protocol constraints (`Ctx: RequestContext` →
    /// `["Ctx": "RequestContext"]`), carried onto the synthesised factory's
    /// `create` signature. Empty when no parameter is constrained.
    package let genericParameterConstraints: [String: String]
    /// The template's `where`-clause requirements, verbatim and without the `where`
    /// keyword (`"Reader.ReadElement == UInt8, Sender.Writer: ~Copyable"`), or `nil`
    /// when there is none. Associated-type and same-type requirements can't be
    /// expressed as per-parameter inheritance, so they're carried separately and
    /// restated on the synthesised factory's `create` — without them a
    /// `~Copyable`/associated-type-constrained middleware won't construct.
    package let genericWhereClause: String?
    /// The injected dependencies — the template's `@Inject` members, resolved
    /// once from the graph when the factory object is constructed.
    package let dependencies: [DependencyParameter]
    package let accessLevel: AccessLevel
    /// Position of the type-name identifier in source — what a diagnostic
    /// navigates to.
    package let location: SourceLocation
    package let originModule: String

    package init(
        keyReference: String,
        typeName: String,
        qualifiedTypeName: String,
        typeKind: String,
        genericParameterNames: [String],
        genericParameterConstraints: [String: String] = [:],
        genericWhereClause: String? = nil,
        dependencies: [DependencyParameter],
        accessLevel: AccessLevel = .internal,
        location: SourceLocation,
        originModule: String
    ) {
        self.keyReference = keyReference
        self.typeName = typeName
        self.qualifiedTypeName = qualifiedTypeName
        self.typeKind = typeKind
        self.genericParameterNames = genericParameterNames
        self.genericParameterConstraints = genericParameterConstraints
        self.genericWhereClause = genericWhereClause
        self.dependencies = dependencies
        self.accessLevel = accessLevel
        self.location = location
        self.originModule = originModule
    }
}
