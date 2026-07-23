// Uniform read access over `DiscoveredBinding`'s three cases — the accessors
// the graph, code emission, and diagnostics read without switching on the case
// themselves.

extension DiscoveredBinding {
    /// The type the binding produces. For `@Singleton` this is the
    /// type's name; for `@Provides` it's the property's annotated type
    /// or the function's return type. Bindings are graph-keyed by this.
    package var boundType: String {
        switch self {
        case .scopeBound(let scopeBound):
            // `@Singleton(as: P.self)` keys the binding as `some P`; construction
            // still uses the concrete type (`qualifiedTypeName`/`typeName`).
            if let identity = scopeBound.explicitIdentity { return "some \(identity)" }
            // A determined generic `@Singleton` keys as its structural identity —
            // each parameter substituted with `some <constraint>`
            // (`TaskController<Repository: TaskRepository>` → `TaskController<some
            // TaskRepository>`) — so it reuses its dependencies' lifted parameters
            // rather than an opaque parameter of its own.
            if allGenericParametersDetermined {
                let arguments = scopeBound.genericParameterNames
                    .map { "some \(scopeBound.genericParameterConstraints[$0]!)" }
                    .joined(separator: ", ")
                return "\(scopeBound.typeName)<\(arguments)>"
            }
            return scopeBound.typeName
        case .provider(let provider): return provider.boundType
        case .aggregate(let aggregate): return aggregate.collectionType
        }
    }

    /// The generic parameters of a `@Singleton` that are *not* determined — an
    /// unconstrained parameter, or one that appears in no dependency (so the
    /// constrained-parameter bridge can't resolve it to a `some P` binding).
    /// A parameter is determined when it appears as a bare-parameter dependency
    /// (`item: Element` → the `some P` binding) *or* as a generic argument inside
    /// a dependency on another lift node (`Box<Element>` → the `Box<some P>`
    /// binding — transitive lift). Empty for a fully-determined generic
    /// `@Singleton` and for non-scope-bound or non-generic bindings.
    package var undeterminedGenericParameters: [String] {
        guard case .scopeBound(let scopeBound) = self else { return [] }
        let dependencyTypes = Set(
            scopeBound.dependencies.map { canonicalTypeName($0.type) }
                + scopeBound.memberInjections.flatMap {
                    $0.parameters.map { canonicalTypeName($0.type) }
                }
        )
        return scopeBound.genericParameterNames.filter { parameter in
            guard let constraint = scopeBound.genericParameterConstraints[parameter],
                constraintIsDetermining(constraint),
                dependencyTypes.contains(parameter)
                    || dependencyTypes.contains(where: { parameterAppearsAsGenericArgument(parameter, in: $0) })
            else { return true }
            return false
        }
    }

    /// Whether every generic parameter of a generic `@Singleton` is determined
    /// (see `undeterminedGenericParameters`). Only such a binding can be a
    /// single-instance lift node; an undetermined one can't be, and the graph
    /// reports it as an error. `false` for non-generic bindings, providers, and
    /// aggregates.
    package var allGenericParametersDetermined: Bool {
        guard case .scopeBound(let scopeBound) = self,
            !scopeBound.genericParameterNames.isEmpty
        else { return false }
        return undeterminedGenericParameters.isEmpty
    }

    /// A lift node — a real graph node keyed by an opaque (`some P`) or
    /// structural identity, never specialised. True for `@Singleton(as:)` nodes
    /// and determined generic `@Singleton`s; false for non-generic bindings,
    /// providers, and undetermined generic `@Singleton`s.
    package var isLiftNode: Bool {
        hasExplicitIdentity || allGenericParametersDetermined
    }

    /// The bound type as referenced from the generated `_WireGraph.swift`
    /// at module scope — qualified with any enclosing type prefix for
    /// `@Singleton`s nested inside another type (typically a
    /// `@Container`). `@Provides` bindings use their declared type
    /// expression as-is; if a user writes a `@Provides` returning a
    /// nested type, they need to qualify the type annotation
    /// themselves (limitation we'll surface as a diagnostic in
    /// iteration 3 if it bites).
    package var boundTypeReference: String {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.qualifiedTypeName
        case .provider(let provider): return provider.boundType
        case .aggregate(let aggregate): return aggregate.collectionType
        }
    }

    /// Dependencies the binding needs at construction — `@Inject`
    /// parameters/properties for `@Singleton`, function parameters for
    /// `@Provides func`, empty for `@Provides let`.
    package var dependencies: [DependencyParameter] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.dependencies
        case .provider(let provider): return provider.dependencies
        case .aggregate(let aggregate): return aggregate.contributors.map(\.dependency)
        }
    }

    /// Post-construction injection points on the binding. Empty for
    /// providers (functions/properties can't host post-init injection
    /// — only `@Singleton`/`@Scoped` types can). For scope-bound
    /// types this carries `@Inject weak var` sugar entries plus any
    /// `@Inject func` entries.
    package var memberInjections: [MemberInjection] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.memberInjections
        case .provider, .aggregate: return []
        }
    }

    /// `true` iff the binding's host type is an `actor`. Member
    /// injection codegen reads this to force an `await` prefix on
    /// method-call injections — calling any method on an actor from
    /// outside its isolation requires `await` regardless of whether
    /// the method itself is `async`. Providers and non-actor
    /// scope-bound types return `false`.
    package var consumerIsActor: Bool {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.typeKind == "actor"
        case .provider, .aggregate: return false
        }
    }

    /// Generic-parameter names declared on the binding. The graph uses
    /// these to skip bindings that can't be resolved without a concrete
    /// specialisation pass (not yet implemented).
    package var genericParameterNames: [String] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.genericParameterNames
        case .provider(let provider): return provider.genericParameterNames
        case .aggregate: return []
        }
    }

    /// Per-generic-parameter protocol constraints, for the constrained-parameter
    /// bridge. Only `@Singleton`/`@Scoped` types carry them; providers and
    /// aggregates have none (a generic `@Provides func` specialises instead).
    package var genericParameterConstraints: [String: String] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.genericParameterConstraints
        case .provider, .aggregate: return [:]
        }
    }

    /// Whether the binding declares an explicit opaque graph identity via
    /// `@Singleton(as: P.self)` — an opaque lift node rather than a binding
    /// keyed by its concrete type.
    package var hasExplicitIdentity: Bool {
        if case .scopeBound(let scopeBound) = self { return scopeBound.explicitIdentity != nil }
        return false
    }

    package var location: SourceLocation {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.location
        case .provider(let provider): return provider.location
        case .aggregate(let aggregate): return aggregate.location
        }
    }

    package var sourcePath: String {
        location.file
    }

    /// The binding's key identifier, or `nil` for unkeyed bindings.
    /// `@Singleton`s are always unkeyed; only `@Provides` can be keyed.
    /// Graph identity is `(boundType, keyIdentifier?)`.
    package var keyIdentifier: String? {
        switch self {
        case .scopeBound: return nil
        case .provider(let provider): return provider.keyIdentifier
        case .aggregate(let aggregate): return aggregate.keyReference
        }
    }

    /// `@Contributes(to:)` annotations on this binding's producer —
    /// empty for non-contributing bindings. The fan-in pass reads this
    /// uniformly across both producer kinds.
    package var contributions: [Contribution] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.contributions
        case .provider(let provider): return provider.contributions
        case .aggregate: return []
        }
    }

    /// Source-level access modifier on the binding's declaration. Drives
    /// the dead-binding warning's visibility gate. Synthesised aggregates
    /// have no source declaration; they report `.internal` (they're never
    /// part of the discovered set the dead-binding analysis walks).
    package var accessLevel: AccessLevel {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.accessLevel
        case .provider(let provider): return provider.accessLevel
        case .aggregate: return .internal
        }
    }

    /// `allowUnused: true` on the binding's macro — the dead-binding-
    /// warning silencer. Aggregates have no macro and never silence.
    package var allowUnused: Bool {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.allowUnused
        case .provider(let provider): return provider.allowUnused
        case .aggregate: return false
        }
    }

    /// The teardown action recorded on the binding's declaration (`@Teardown`), or `nil`
    /// when it has none. `@Singleton`/`@Scoped` carry the member form; `@Provides` the
    /// producer form; aggregates never have one. M4's teardown walk emits a call for each
    /// binding that has one, in reverse construction order.
    package var teardown: TeardownAction? {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.teardown
        case .provider(let provider): return provider.teardown
        case .aggregate: return nil
        }
    }

    /// `true` when this binding carries a bare `@Replaces` marker — it supersedes
    /// the slot it produces (its own identity). Read by the graph's
    /// duplicate-binding resolution: a `@Replaces` binding wins over a same-slot
    /// binding from another module instead of colliding with it. Aggregates are
    /// never replacers.
    package var isReplacer: Bool {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.isReplacer
        case .provider(let provider): return provider.isReplacer
        case .aggregate: return false
        }
    }
}
