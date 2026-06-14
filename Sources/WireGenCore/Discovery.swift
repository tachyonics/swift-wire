import SwiftParser
import SwiftSyntax

// MARK: - Source positions

/// A position in a source file — file path plus 1-based line and column.
/// Carried by every discovered binding and dependency so diagnostics can
/// emit `file:line:col: error: ...` output that Swift toolchains
/// (Xcode, the swiftc-driven build pipeline) surface as clickable
/// errors. Discovery populates these from `SwiftSyntax`'s
/// `SourceLocationConverter`; tests construct them directly.
package struct SourceLocation: Sendable, Hashable {
    package let file: String
    package let line: Int
    package let column: Int

    package init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    /// `file:line:col` — the prefix Swift compiler diagnostics use, so
    /// downstream tools recognise the position and link it back to the
    /// source.
    package var formattedPrefix: String {
        "\(file):\(line):\(column)"
    }
}

// MARK: - Discovery model

/// Identifies a `@Scoped` binding's scope partition. Today only the
/// seed type matters; `within` is reserved for the future
/// `@Scoped(within:)` hierarchical-scope work and is always `nil`.
/// Treating it as a structured key from the start means reopening
/// hierarchical scopes later doesn't reshape this type.
package struct ScopeKey: Hashable, Sendable {
    /// Canonical text of the seed-type expression from the `@Scoped`
    /// argument (e.g. `"HBRequestSeed"`).
    package let seed: String
    /// Canonical text of the enclosing parent scope's seed type, when
    /// hierarchical scopes are in use. Always `nil` today.
    package let within: String?

    package init(seed: String, within: String? = nil) {
        self.seed = seed
        self.within = within
    }
}

/// Identifies where a discovered binding belongs in the graph
/// space. Two orthogonal axes:
///
/// - `container`: `nil` for the default graph; non-nil for a named
///   `@Container`'s graph. Selecting a container at the entry point
///   replaces the default graph atomically — module-scope bindings
///   don't merge in (README's atomic-selection rule).
/// - `scope`: `nil` for singleton-lifetime bindings (process-wide for
///   `@Singleton`, container-wide for an in-container `@Provides`);
///   non-nil for `@Scoped(seed:)` bindings, identifying the per-seed
///   scope partition.
///
/// All four combinations are valid placements:
///
/// | container | scope | Placement                                |
/// | --------- | ----- | ---------------------------------------- |
/// | `nil`     | `nil` | Default graph, singleton lifetime        |
/// | `"Foo"`   | `nil` | `Foo` container's graph, singletons      |
/// | `nil`     | seed  | Default graph's per-seed scope           |
/// | `"Foo"`   | seed  | `Foo` container's per-seed scope         |
///
/// Container × scope is orthogonal: a `@Container`-selected graph
/// has its own scoped pools, separate from module-scope ones.
package struct Partition: Hashable, Sendable {
    package let container: String?
    package let scope: ScopeKey?

    package init(container: String? = nil, scope: ScopeKey? = nil) {
        self.container = container
        self.scope = scope
    }

    /// The default-graph singleton partition — `container == nil`,
    /// `scope == nil`. Convenience for tests and call sites that
    /// build the most common partition by name.
    package static let `default` = Partition()
}

/// One binding the build plugin found in source — either a `@Singleton`
/// type whose construction Wire owns, or a `@Provides`-declared property
/// or function the user wrote to supply a value.
///
/// The graph algorithm operates uniformly on `DiscoveredBinding` via the
/// accessors below. The kind only matters at code emission, where the
/// construction call shape differs (`Type(args)` vs `accessPath` vs
/// `accessPath(args)`).
package enum DiscoveredBinding: Sendable {
    case scopeBound(DiscoveredScopeBoundType)
    case provider(DiscoveredProvider)
}

extension DiscoveredBinding {
    /// The type the binding produces. For `@Singleton` this is the
    /// type's name; for `@Provides` it's the property's annotated type
    /// or the function's return type. Bindings are graph-keyed by this.
    package var boundType: String {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.typeName
        case .provider(let provider): return provider.boundType
        }
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
        }
    }

    /// Dependencies the binding needs at construction — `@Inject`
    /// parameters/properties for `@Singleton`, function parameters for
    /// `@Provides func`, empty for `@Provides let`.
    package var dependencies: [DependencyParameter] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.dependencies
        case .provider(let provider): return provider.dependencies
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
        case .provider: return []
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
        case .provider: return false
        }
    }

    /// Generic-parameter names declared on the binding. The graph uses
    /// these to skip bindings that can't be resolved without a concrete
    /// specialisation pass (not yet implemented).
    package var genericParameterNames: [String] {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.genericParameterNames
        case .provider(let provider): return provider.genericParameterNames
        }
    }

    package var location: SourceLocation {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.location
        case .provider(let provider): return provider.location
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
        }
    }
}

/// One `@Singleton`-annotated type found in a source file, with the
/// dependency declaration extracted from either an `@Inject`-marked init
/// or from `@Inject` stored properties on the type.
///
/// `typeName` is the simple type name (`MockService`); the graph keys
/// bindings by this. `qualifiedTypeName` is the same name prefixed by
/// any enclosing types' names (`TestContainer.MockService` for a
/// `@Singleton` nested inside a `@Container` enum, or just
/// `MockService` for a top-level `@Singleton`). Code emission uses
/// `qualifiedTypeName` at the construction site since the generated
/// `_wireBootstrap...` function lives at module scope and can't see
/// nested types unqualified.
///
/// Despite the name, this type also models `@Scoped(seed:)` bindings.
/// `@Scoped` and `@Singleton` synthesise identical members and route
/// the same way through the graph — the only structural difference is
/// the `scopeKey`, which is non-nil for `@Scoped` bindings (recording
/// the seed type) and nil for `@Singleton`. Renaming this type would
/// have churned a lot of tests for cosmetic value.
package struct DiscoveredScopeBoundType: Sendable {
    package let typeName: String
    package let qualifiedTypeName: String
    package let typeKind: String
    package let genericParameterNames: [String]
    package let dependencies: [DependencyParameter]
    /// Position of the type-name identifier in source — what the user
    /// would navigate to from a diagnostic.
    package let location: SourceLocation
    /// `nil` for `@Singleton` bindings; non-nil for `@Scoped`
    /// bindings, carrying the canonical seed-type expression (and a
    /// `within` slot reserved for future hierarchical-scope work,
    /// always `nil` today).
    package let scopeKey: ScopeKey?
    /// `true` when the type carries a user-written `@Inject init`
    /// with `async` in its effect specifiers. The macro-synthesised
    /// init (from `@Inject` stored properties) is always sync, so
    /// this is `false` unless a custom `@Inject init() async`
    /// declaration overrides synthesis.
    package let initIsAsync: Bool
    /// `true` when the type carries a user-written `@Inject init`
    /// with `throws` in its effect specifiers. Same caveat as
    /// `initIsAsync` for macro-synthesised inits.
    package let initIsThrowing: Bool
    /// Post-construction injection points on this type. Comes from
    /// two source forms:
    /// - `@Inject weak var x: T?` — sugar, becomes a
    ///   `.propertyAssignment` member injection.
    /// - `@Inject func setX(_ x: T)` — general form, becomes a
    ///   `.methodCall` member injection.
    /// Each member injection's parameters resolve through the graph
    /// the same way init-time deps do, but they're excluded from
    /// cycle detection (post-init delivery breaks construction-time
    /// edges) and emitted as a separate block after the construction
    /// sequence in the generated bootstrap.
    package let memberInjections: [MemberInjection]
    /// Source-level access modifier on the type declaration. Drives
    /// the declaration-too-private error (fires for `fileprivate` /
    /// `private`) and the dead-binding warning's permissive-on-
    /// public rule. See `Documentation/Notes/VisibilityModel.md`.
    package let accessLevel: AccessLevel

    package var sourcePath: String { location.file }

    package init(
        typeName: String,
        qualifiedTypeName: String? = nil,
        typeKind: String,
        genericParameterNames: [String],
        dependencies: [DependencyParameter],
        location: SourceLocation,
        scopeKey: ScopeKey? = nil,
        initIsAsync: Bool = false,
        initIsThrowing: Bool = false,
        memberInjections: [MemberInjection] = [],
        accessLevel: AccessLevel = .internal
    ) {
        self.typeName = typeName
        // Default to the simple name so existing call sites that pass
        // only `typeName` (top-level singletons in tests, etc.) keep
        // working without explicit qualification.
        self.qualifiedTypeName = qualifiedTypeName ?? typeName
        self.typeKind = typeKind
        self.genericParameterNames = genericParameterNames
        self.dependencies = dependencies
        self.location = location
        self.scopeKey = scopeKey
        self.initIsAsync = initIsAsync
        self.initIsThrowing = initIsThrowing
        self.memberInjections = memberInjections
        self.accessLevel = accessLevel
    }
}

/// One post-construction injection point on a `@Singleton` / `@Scoped`
/// type. Delivers deps that don't (or can't) flow through the type's
/// constructor:
///
/// - `@Inject weak var x: T?` — Swift won't let `weak` be an init
///   parameter, so the dep is delivered post-construct by direct
///   property assignment. Shape: `.propertyAssignment`.
/// - `@Inject func setX(_ x: T) [async] [throws]` — user chose
///   method-level injection deliberately, typically to wire deps
///   into custom storage (Mutex-wrapped weak ref, actor message,
///   etc.). Shape: `.methodCall`. The function's effect specifiers
///   carry through to the call site.
///
/// The graph treats member injection parameters as edges-for-
/// missing-binding but NOT for cycle detection — the construction-
/// time edge doesn't exist, the consumer's init completes without
/// these deps, and the bootstrap wires them after. See
/// `Documentation/Notes/WeakInjectionSupport.md` for the design
/// depth and `WireGenCore/Graph.swift` for the cycle-detection
/// branch.
package struct MemberInjection: Sendable {
    package let shape: Shape
    package let parameters: [DependencyParameter]
    /// `true` for `@Inject func ... async` methods. Drives `await`
    /// prefixing at the post-init call site. Always `false` for
    /// `.propertyAssignment` (a direct assignment is sync by
    /// language design).
    package let isAsync: Bool
    /// `true` for `@Inject func ... throws` methods. Drives `try`
    /// prefixing. Always `false` for `.propertyAssignment`.
    package let isThrowing: Bool
    /// Position of the source-level declaration — the `weak var`
    /// property identifier, or the `func` name.
    package let location: SourceLocation
    /// Source-level access modifier on the member declaration. Both
    /// `@Inject weak var` properties and `@Inject func` methods are
    /// referenced post-construct by Wire's generated bootstrap, so
    /// their visibility constrains whether the generated code can
    /// reach them. `fileprivate` and `private` produce a declaration-
    /// too-private error. See
    /// `Documentation/Notes/VisibilityModel.md` for the asymmetry
    /// with constructor-injected `@Inject var/let`.
    package let accessLevel: AccessLevel
    /// Setter-restriction modifier on the source declaration, when
    /// present (`private(set)`, `fileprivate(set)`, etc.). `nil`
    /// when the source has no setter restriction. Relevant only for
    /// `.propertyAssignment` shape: the bootstrap writes to a weak
    /// property post-construct, so a setter restriction tighter
    /// than `internal` blocks that write even when the property's
    /// read access is otherwise reachable. `.methodCall` shape
    /// always carries `nil` here (functions don't have separate
    /// setter access).
    package let setterAccessLevel: AccessLevel?

    package init(
        shape: Shape,
        parameters: [DependencyParameter],
        isAsync: Bool = false,
        isThrowing: Bool = false,
        location: SourceLocation,
        accessLevel: AccessLevel = .internal,
        setterAccessLevel: AccessLevel? = nil
    ) {
        self.shape = shape
        self.parameters = parameters
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.location = location
        self.accessLevel = accessLevel
        self.setterAccessLevel = setterAccessLevel
    }

    /// The effective access level Wire's generated bootstrap needs
    /// to be able to write at for `.propertyAssignment` shape.
    /// Combines the property's read access with the setter
    /// restriction: a `private(set)` modifier on an otherwise
    /// `internal` property leaves the effective write access at
    /// `private`. Falls back to `accessLevel` when no setter
    /// restriction is present.
    package var effectiveWriteAccessLevel: AccessLevel {
        setterAccessLevel ?? accessLevel
    }

    package enum Shape: Sendable, Equatable {
        /// Sugar form from `@Inject weak var x: T?`. Codegen emits
        /// `consumer.<propertyName> = <parameter[0]>` at the post-
        /// init step. Single-parameter, sync, non-throwing.
        case propertyAssignment(propertyName: String)
        /// General form from `@Inject func setX(_ x: T)`. Codegen
        /// emits `[try] [await] consumer.<methodName>(<args...>)`
        /// at the post-init step. Multi-parameter, effects driven
        /// by the method's signature.
        case methodCall(methodName: String)
    }
}

/// One `@Provides`-declared binding — either a property (no
/// dependencies) or a function whose parameters become its
/// dependencies. Lives at module scope or as a `static` member of any
/// non-`@Container` enclosing type (struct, class, enum, actor).
///
/// The `accessPath` is what the generated bootstrap writes after the
/// module qualifier — `logger` for a top-level `let logger`, or
/// `Config.dbURL` for a `static let dbURL` on `enum Config`. Nested
/// enclosing types are joined with `.` (e.g., `Outer.Inner.foo`).
package struct DiscoveredProvider: Sendable {
    package let boundType: String
    package let accessPath: String
    package let form: Form
    package let dependencies: [DependencyParameter]
    package let genericParameterNames: [String]
    /// Position of the property/function identifier — what the user
    /// would navigate to from a diagnostic.
    package let location: SourceLocation
    /// Canonical text of the `@Provides(<expr>)` argument, or `nil` for
    /// the unkeyed form. Two bindings of the same type with different
    /// `keyIdentifier`s coexist in the graph; same type with same key
    /// is a duplicate.
    package let keyIdentifier: String?
    /// Concrete type arguments to splice into the call site when this
    /// provider was produced by specialising a generic provider
    /// function — e.g. `["DynamoDBTable"]` for a specialised
    /// `func makeRepo<T>() -> Repository<T>` invoked as
    /// `makeRepo<DynamoDBTable>()`. Empty for non-specialised
    /// providers (concrete property and function bindings); only the
    /// generic-specialisation phase populates this.
    package let concreteGenericArguments: [String]
    /// `true` when the binding's source is `async` — `@Provides func
    /// makeFoo() async -> Foo`, or a computed `@Provides var x: Foo
    /// { get async }`. Drives `await ` prefixing at the call site
    /// during code emission. Stored `@Provides let` bindings can't be
    /// async, so this is `false` for property-form providers other
    /// than computed properties with `get async`.
    package let isAsync: Bool
    /// `true` when the binding's source is `throws` — `@Provides func
    /// makeFoo() throws -> Foo`, or a computed `@Provides var x: Foo
    /// { get throws }`. Drives `try ` prefixing at the call site.
    package let isThrowing: Bool
    /// Source-level access modifier on the property or function.
    /// Drives the declaration-too-private error and the
    /// dead-binding warning. See
    /// `Documentation/Notes/VisibilityModel.md`.
    package let accessLevel: AccessLevel

    package var sourcePath: String { location.file }

    package init(
        boundType: String,
        accessPath: String,
        form: Form,
        dependencies: [DependencyParameter],
        genericParameterNames: [String],
        location: SourceLocation,
        keyIdentifier: String? = nil,
        concreteGenericArguments: [String] = [],
        isAsync: Bool = false,
        isThrowing: Bool = false,
        accessLevel: AccessLevel = .internal
    ) {
        self.boundType = boundType
        self.accessPath = accessPath
        self.form = form
        self.dependencies = dependencies
        self.genericParameterNames = genericParameterNames
        self.location = location
        self.keyIdentifier = keyIdentifier
        self.concreteGenericArguments = concreteGenericArguments
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.accessLevel = accessLevel
    }

    /// Whether the binding source is a property (read its value directly)
    /// or a function (call it with resolved arguments).
    package enum Form: Sendable, Equatable {
        case property
        case function
    }
}

/// One dependency that the synthesised (or user-marked) initialiser takes
/// — i.e. one parameter Wire must resolve from the graph at construction
/// time.
///
/// `name` is the external argument label used at the call site. `nil`
/// represents a wildcard label (the `_` form, e.g. `init(_ a: A)`),
/// where the call site omits the label entirely. Property-based
/// injection always produces a concrete label (the property name);
/// only `@Inject init(_ x: Foo)` produces a `nil` name.
package struct DependencyParameter: Sendable {
    package let name: String?
    package let type: String
    package let kind: DependencyKind
    /// Position of the parameter or property identifier in source — the
    /// `@Inject` site (or `@Provides func` parameter) the diagnostic
    /// should point at when this dependency can't be resolved.
    package let location: SourceLocation
    /// Canonical text of the `@Inject(<expr>)` argument when the
    /// consumer is selecting a keyed binding, or `nil` for the unkeyed
    /// form. Unkeyed deps match only unkeyed bindings; keyed deps
    /// match only same-key bindings (Dagger-style — keys partition the
    /// binding space).
    package let keyIdentifier: String?
    /// True when this init-time dependency came from an `@Inject weak
    /// let`. Diagnostic-only metadata: a `weak let` edge that closes a
    /// cycle can be broken by converting it to `weak var` (post-construct
    /// delivery), so the cyclic-dependency error points at it. Doesn't
    /// affect resolution or codegen. See `OptionalMatchingAndCycles.md`.
    package let isWeakLet: Bool

    package init(
        name: String?,
        type: String,
        kind: DependencyKind,
        location: SourceLocation,
        keyIdentifier: String? = nil,
        isWeakLet: Bool = false
    ) {
        self.name = name
        self.type = type
        self.kind = kind
        self.location = location
        self.keyIdentifier = keyIdentifier
        self.isWeakLet = isWeakLet
    }
}

/// Swift access-level modifier on a binding declaration. Captured
/// by discovery to drive two diagnostics — the declaration-too-
/// private error (any binding less visible than `internal` is
/// invisible to Wire's generated code, which lives in a separate
/// file) and the dead-binding warning (non-public bindings with
/// no consumers in the visible build are flagged; public bindings
/// stay silent because consumers may exist downstream). See
/// `Documentation/Notes/VisibilityModel.md` for the design
/// contract.
///
/// `internal` is the Swift default when no modifier is present.
package enum AccessLevel: Sendable, Equatable {
    case `open`
    case `public`
    case `package`
    case `internal`
    case `fileprivate`
    case `private`

    /// True iff Wire's generated bootstrap can textually reference a
    /// declaration at this access level. `internal` and higher are
    /// visible to the generated `_WireGraph.swift`; `fileprivate`
    /// and `private` aren't.
    package var isVisibleToGeneratedCode: Bool {
        switch self {
        case .open, .public, .package, .internal: return true
        case .fileprivate, .private: return false
        }
    }

    /// True iff this declaration is externally exposed — consumers
    /// may exist downstream in modules Wire can't see. Drives the
    /// dead-binding warning's "stay silent on public" rule.
    package var isPubliclyExposed: Bool {
        switch self {
        case .open, .public: return true
        case .package, .internal, .fileprivate, .private: return false
        }
    }

    /// Human-readable name matching the Swift keyword, for use in
    /// diagnostic messages.
    package var keyword: String {
        switch self {
        case .open: return "open"
        case .public: return "public"
        case .package: return "package"
        case .internal: return "internal"
        case .fileprivate: return "fileprivate"
        case .private: return "private"
        }
    }

    /// Ordering from least restrictive (`open` = 0) to most restrictive
    /// (`private` = 5). Used to combine a declaration's own access with
    /// the access of every enclosing scope: Swift caps a member's
    /// *effective* access at the most restrictive level in that chain.
    package var restrictionRank: Int {
        switch self {
        case .open: return 0
        case .public: return 1
        case .package: return 2
        case .internal: return 3
        case .fileprivate: return 4
        case .private: return 5
        }
    }

    /// The more restrictive of `self` and `other` — i.e. the effective
    /// access of a declaration written at `self` but nested inside a
    /// scope whose access is `other`. A `@Provides` written `internal`
    /// inside a `private enum` is effectively `private`, and so
    /// invisible to Wire's generated bootstrap.
    package func mostRestrictive(with other: AccessLevel) -> AccessLevel {
        restrictionRank >= other.restrictionRank ? self : other
    }
}

package enum DependencyKind: Sendable, Equatable {
    case injectProperty
    case injectInitParameter
    /// A parameter of an `@Inject func` method (or of a synthesised
    /// member-injection entry derived from `@Inject weak var` sugar).
    /// Lives inside a `MemberInjection` on the host type's
    /// `DiscoveredScopeBoundType` rather than directly in the binding's
    /// init-time `dependencies` list. Downstream stages distinguish:
    /// graph excludes these from cycle detection (post-init delivery),
    /// codegen emits them in the post-construction block via the
    /// member injection's call shape (property assignment or method
    /// call). See `Documentation/Notes/WeakInjectionSupport.md` for
    /// the design depth.
    case injectMethodParameter
    case providerFunctionParameter
}

// MARK: - Top-level entry points

/// Bindings and imports discovered in a single source file. Both
/// products of one parse — the visitor walks the tree once and
/// captures `@Singleton`/`@Provides` declarations alongside `import`
/// statements, partitioning bindings between the default graph and
/// any `@Container` enums encountered.
package struct SourceFileDiscovery: Sendable {
    /// Every discovered binding, partitioned by `(container, scope)`.
    /// One uniform structure covers all four placement combinations
    /// described on `Partition`: default-graph singletons,
    /// container-graph singletons, default-graph scoped, and
    /// container-graph scoped. Callers that need the historical
    /// "default bindings" / "named container's bindings" slices use
    /// the convenience accessors below, or filter `allBindings` by
    /// `partition.container` / `partition.scope` directly.
    package let allBindings: [Partition: [DiscoveredBinding]]
    package let imports: [String]
    /// Source-pattern warnings the visitor surfaced during this file's
    /// parse — things like `@Inject` on an extension init (silently
    /// ignored by the macro) or `@Container` combined with a scope
    /// annotation. Informational; WireGen renders them but does not
    /// fail the build on warnings alone.
    package let warnings: [Diagnostic]
    /// `@Provides` sites found inside *unannotated* extensions
    /// (`extension Foo { @Provides ... }` where the extension itself
    /// is not `@Container`-annotated). Needs aggregation across all
    /// files to resolve into a warning — the warning fires when the
    /// extended type has a `@Container` declaration *somewhere*, and
    /// only `WireGen` knows the module-wide container-name set.
    package let unannotatedExtensionProvides: [UnannotatedExtensionProvides]
    /// Module-scope `typealias` declarations captured per-file and
    /// aggregated across the module. Drives the typealias hint that
    /// missing-binding diagnostics use to point at the underlying type
    /// when a typealias was injected but its underlying type IS bound.
    package let typealiases: [DiscoveredTypealias]
    /// Simple names of every primary type declaration (struct, class,
    /// actor, enum, protocol) found in this file. Aggregated across the
    /// module by `WireGen` to drive the cross-module-extension warning
    /// — an unannotated `extension Foo` whose `Foo` isn't in this set
    /// is probably extending an imported type.
    package let declaredTypeNames: [String]
    /// `init`s found inside `extension` blocks that aren't marked
    /// `@Inject`. Resolved to a warning when the extended type is
    /// `@Singleton` somewhere in the module — those inits collide
    /// with or shadow the macro-generated init.
    package let nonInjectExtensionInits: [NonInjectExtensionInit]

    package init(
        allBindings: [Partition: [DiscoveredBinding]] = [:],
        imports: [String],
        warnings: [Diagnostic] = [],
        unannotatedExtensionProvides: [UnannotatedExtensionProvides] = [],
        typealiases: [DiscoveredTypealias] = [],
        declaredTypeNames: [String] = [],
        nonInjectExtensionInits: [NonInjectExtensionInit] = []
    ) {
        self.allBindings = allBindings
        self.imports = imports
        self.warnings = warnings
        self.unannotatedExtensionProvides = unannotatedExtensionProvides
        self.typealiases = typealiases
        self.declaredTypeNames = declaredTypeNames
        self.nonInjectExtensionInits = nonInjectExtensionInits
    }
}

extension SourceFileDiscovery {
    /// Default-graph singleton bindings: `partition.container == nil`
    /// and `partition.scope == nil`. Convenience accessor for the
    /// most-common slice; equivalent to
    /// `allBindings[.default] ?? []`.
    package var bindings: [DiscoveredBinding] {
        allBindings[.default] ?? []
    }

    /// Singleton bindings inside `@Container`-annotated declarations,
    /// grouped by container name. Today every entry is `scope == nil`;
    /// once `@Scoped` lands, per-container scoped bindings live in
    /// their own partitions and are derived separately.
    package var containerBindings: [String: [DiscoveredBinding]] {
        var result: [String: [DiscoveredBinding]] = [:]
        for (partition, bindings) in allBindings {
            guard let container = partition.container, partition.scope == nil else { continue }
            result[container, default: []].append(contentsOf: bindings)
        }
        return result
    }
}

/// One module-scope `typealias` declaration captured during discovery.
/// Used at validation time to enrich missing-binding diagnostics: if
/// `@Inject var x: UserID` fails to resolve but `UserID` is a typealias
/// of a type that IS bound, a `note:` line points at the underlying
/// type so the user understands why the lookup didn't match. Typealiases
/// are not unwrapped during resolution — `typealias UserID = UUID`
/// followed by separate keyed bindings for each is a legitimate
/// discriminator pattern.
package struct DiscoveredTypealias: Sendable {
    /// The typealias's own name, as written (e.g. `"UserID"`).
    package let name: String
    /// The right-hand-side type expression, trimmed (e.g. `"UUID"`).
    package let underlyingType: String
    package let location: SourceLocation

    package init(name: String, underlyingType: String, location: SourceLocation) {
        self.name = name
        self.underlyingType = underlyingType
        self.location = location
    }
}

/// One `init` site found inside an extension that doesn't carry
/// `@Inject`. Recorded as a candidate; resolves to a warning when the
/// extended type is `@Singleton`-annotated somewhere in the module —
/// the macro-generated init either collides with this one (Swift
/// redeclaration error) or silently shadows it. The Wire diagnostic
/// fires before either of those confusing outcomes does.
package struct NonInjectExtensionInit: Sendable {
    /// Simple name of the extended type — what we cross-reference
    /// against the module-wide `@Singleton`-name set.
    package let extendedType: String
    /// Anchor at the `init` keyword.
    package let location: SourceLocation

    package init(extendedType: String, location: SourceLocation) {
        self.extendedType = extendedType
        self.location = location
    }
}

/// One `@Provides` site found inside an unannotated extension.
/// Carried through discovery as a candidate; the build plugin
/// resolves it into a `Diagnostic` after the module-wide
/// `@Container`-name set is available.
package struct UnannotatedExtensionProvides: Sendable {
    /// The extension's extended type name — what the warning checks
    /// against the container set.
    package let extendedType: String
    /// Display name of the offending `@Provides` declaration, for
    /// the warning message (e.g. property/function source name).
    package let providerName: String
    /// Anchor for the warning's `file:line:col:` prefix.
    package let location: SourceLocation

    package init(extendedType: String, providerName: String, location: SourceLocation) {
        self.extendedType = extendedType
        self.providerName = providerName
        self.location = location
    }
}

/// Parse one source file and return every `@Singleton` and `@Provides`
/// binding it contains, plus every `import` declaration. Singletons
/// follow the same priority rule as `SingletonMacro` for dependencies
/// (an `@Inject`-marked init's parameter list takes precedence over
/// `@Inject` stored properties). Providers come from module-scope
/// `let`/`func` declarations and from `static let`/`static func`
/// members of enclosing types. Imports are captured verbatim,
/// preserving access modifiers (`@testable`, `@_implementationOnly`,
/// etc.) so the build plugin can propagate them into the generated
/// `_WireGraph.swift`.
package func discover(
    in source: String,
    sourcePath: String
) -> SourceFileDiscovery {
    let syntaxTree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: sourcePath, tree: syntaxTree)
    let visitor = BindingDiscovery(sourcePath: sourcePath, converter: converter)
    visitor.walk(syntaxTree)
    return SourceFileDiscovery(
        allBindings: visitor.allBindings,
        imports: visitor.imports,
        warnings: visitor.warnings,
        unannotatedExtensionProvides: visitor.unannotatedExtensionProvides,
        typealiases: visitor.typealiases,
        declaredTypeNames: visitor.declaredTypeNames,
        nonInjectExtensionInits: visitor.nonInjectExtensionInits
    )
}

/// Render a human-readable summary of bindings discovered grouped by
/// source file. Files with no discoveries are omitted to keep the
/// report scannable.
package func renderDiscoveryReport(
    perFile: [(path: String, items: [DiscoveredBinding])]
) -> String {
    var lines: [String] = []
    lines.append("WireGen discovery report")
    lines.append("")

    var totalCount = 0
    let sourceFileCount = perFile.count

    for (path, items) in perFile {
        guard !items.isEmpty else { continue }
        lines.append("\(path):")
        for item in items {
            totalCount += 1
            switch item {
            case .scopeBound(let scopeBound):
                renderScopeBoundType(scopeBound, into: &lines)
            case .provider(let provider):
                renderProvider(provider, into: &lines)
            }
        }
        lines.append("")
    }

    lines.append(
        "discovered \(totalCount) binding(s) across \(sourceFileCount) source file(s)"
    )

    return lines.joined(separator: "\n")
}

private func renderScopeBoundType(_ item: DiscoveredScopeBoundType, into lines: inout [String]) {
    let generics =
        item.genericParameterNames.isEmpty
        ? ""
        : "<\(item.genericParameterNames.joined(separator: ", "))>"
    lines.append("  @Singleton \(item.typeKind) \(item.typeName)\(generics)")
    if item.dependencies.isEmpty {
        lines.append("    (no dependencies)")
    } else {
        for dep in item.dependencies {
            lines.append("    \(dependencyLine(dep))")
        }
    }
}

private func renderProvider(_ item: DiscoveredProvider, into lines: inout [String]) {
    let generics =
        item.genericParameterNames.isEmpty
        ? ""
        : "<\(item.genericParameterNames.joined(separator: ", "))>"
    let formLabel: String
    switch item.form {
    case .property: formLabel = "let"
    case .function: formLabel = "func"
    }
    lines.append(
        "  @Provides \(formLabel) \(item.accessPath)\(generics) -> \(item.boundType)"
    )
    if item.dependencies.isEmpty {
        lines.append("    (no dependencies)")
    } else {
        for dep in item.dependencies {
            lines.append("    \(dependencyLine(dep))")
        }
    }
}

private func dependencyLine(_ dep: DependencyParameter) -> String {
    let kindLabel: String
    switch dep.kind {
    case .injectProperty: kindLabel = "@Inject property"
    case .injectInitParameter: kindLabel = "@Inject init parameter"
    case .injectMethodParameter: kindLabel = "@Inject method parameter"
    case .providerFunctionParameter: kindLabel = "@Provides function parameter"
    }
    // Wildcard-label parameters render as `_` to match the source-level
    // form. The sentinel only appears in human-facing output here;
    // codegen receives the actual `nil` from `DependencyParameter.name`.
    let displayName = dep.name ?? "_"
    return "\(displayName): \(dep.type)   (\(kindLabel))"
}
