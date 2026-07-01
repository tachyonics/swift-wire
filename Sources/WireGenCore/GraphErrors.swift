// The value types graph validation and discovery surface as errors, hints, and
// diagnostics. `GraphResult` and the construction pipeline live in `Graph.swift`;
// these are the data they carry.

/// A generic `@Singleton` that can't be a single instance: at least one generic
/// parameter is undetermined (unconstrained, or never a dependency), so it would
/// vary per use. The fix is to constrain the parameter (so it resolves to one
/// binding) or move to a `@Provides func` parameterised factory.
package struct InvalidGenericSingleton: Sendable {
    package let binding: DiscoveredBinding
    package let undeterminedParameters: [String]

    package init(binding: DiscoveredBinding, undeterminedParameters: [String]) {
        self.binding = binding
        self.undeterminedParameters = undeterminedParameters
    }
}

/// One unresolved dependency — an `@Inject` parameter/property or a
/// `@Provides func` parameter whose declared type isn't satisfied by
/// any other discovered binding.
package struct MissingBinding: Sendable {
    package let consumer: DiscoveredBinding
    package let dependency: DependencyParameter
    /// Optional hint surfaced when the dependency's type matches a
    /// module-scope `typealias` whose underlying type IS bound — the
    /// user likely expected the typealias to be unwrapped at lookup.
    /// Renders as a `note:` line beneath the primary missing-binding
    /// error.
    package let typealiasHint: TypealiasHint?
    /// Optional hint surfaced when the dependency's type IS bound,
    /// but in a different scope partition than the consumer's. The
    /// most common case: a `@Singleton` `@Inject`s a `@Scoped` type
    /// directly. Renders as `note:` lines beneath the primary
    /// missing-binding error, including a fix-it suggestion.
    package let crossScopeHint: CrossScopeHint?
    /// Optional hint surfaced when the dependency went unmatched because
    /// of an *optionality* mismatch — a non-optional dependency with only
    /// an optional producer (the asymmetry), or a missing optional that
    /// still needs an explicit producer. Renders as a `note:` line.
    package let optionalMismatchHint: OptionalMismatchHint?

    package init(
        consumer: DiscoveredBinding,
        dependency: DependencyParameter,
        typealiasHint: TypealiasHint? = nil,
        crossScopeHint: CrossScopeHint? = nil,
        optionalMismatchHint: OptionalMismatchHint? = nil
    ) {
        self.consumer = consumer
        self.dependency = dependency
        self.typealiasHint = typealiasHint
        self.crossScopeHint = crossScopeHint
        self.optionalMismatchHint = optionalMismatchHint
    }
}

/// Carries the data needed to render the typealias-aware
/// missing-binding note. The note explains *why* the lookup didn't
/// match — the dependency was written with the typealias, but
/// resolution is by canonical type name and typealiases aren't
/// unwrapped (preserving the discriminator pattern where two
/// typealiases of the same underlying type are distinct slots).
package struct TypealiasHint: Sendable {
    /// The typealias's source name, as written by the consumer.
    package let typealiasName: String
    /// The underlying type that IS bound in the graph.
    package let underlyingType: String
    /// Where the typealias was declared, for the note's prefix.
    package let typealiasLocation: SourceLocation

    package init(
        typealiasName: String,
        underlyingType: String,
        typealiasLocation: SourceLocation
    ) {
        self.typealiasName = typealiasName
        self.underlyingType = underlyingType
        self.typealiasLocation = typealiasLocation
    }
}

/// Carries the data needed to render the cross-scope missing-binding
/// note + fix-it. Surfaced when a missing dependency's `(type, key)`
/// is bound in one or more partitions — just not in the consumer's
/// scope partition. The most common case is a `@Singleton` directly
/// `@Inject`ing a `@Scoped(seed:)` binding: the binding exists, but
/// in a per-seed scope the consumer can't reach without scoping
/// itself or borrowing through an appropriate wrapper.
///
/// `matches` lists every partition where the binding lives, in
/// deterministic sorted order. When only one match exists, the
/// fix-it is tailored to that specific mismatch shape (wider-vs-
/// narrower scope, sibling seeded scopes, cross-container). When
/// multiple matches exist (the type is bound in several
/// partitions, none reachable from the consumer), the fix-it
/// shifts to a multiplicity-aware message.
///
/// `consumerScopeDescription` is the human-readable scope label
/// for the consumer (`"@Singleton"`, `"@Scoped(seed: X.self)"`,
/// `"@Container Foo"`, etc.).
package struct CrossScopeHint: Sendable {
    package let matches: [Match]
    package let consumerScopeDescription: String
    package let fixItSuggestion: String

    package init(
        matches: [Match],
        consumerScopeDescription: String,
        fixItSuggestion: String
    ) {
        self.matches = matches
        self.consumerScopeDescription = consumerScopeDescription
        self.fixItSuggestion = fixItSuggestion
    }

    /// One partition where the missing dependency's type is bound.
    /// Multiple matches render as multiple `note:` lines so the
    /// user sees every place the binding lives.
    package struct Match: Sendable {
        package let scopeDescription: String
        package let location: SourceLocation

        package init(scopeDescription: String, location: SourceLocation) {
            self.scopeDescription = scopeDescription
            self.location = location
        }
    }
}

/// Two or more bindings claim the same `(type, key)` identity, leaving
/// the graph fundamentally ambiguous about which one to use at
/// injection sites. With explicit-key disambiguation, two bindings of
/// the same type with *different* keys coexist — only same `(type, key)`
/// fires this error.
package struct DuplicateBinding: Sendable {
    package let boundType: String
    /// The key identifier shared by all of the duplicates, or `nil`
    /// when they're all unkeyed. Surfaced in the diagnostic so the user
    /// sees which slot is overloaded; also drives the fix-it text
    /// (suggest adding keys when none of the duplicates carry one).
    package let keyIdentifier: String?
    package let bindings: [DiscoveredBinding]

    package init(
        boundType: String,
        keyIdentifier: String? = nil,
        bindings: [DiscoveredBinding]
    ) {
        self.boundType = boundType
        self.keyIdentifier = keyIdentifier
        self.bindings = bindings
    }
}

/// One source-pattern diagnostic surfaced by discovery or graph
/// validation. Renders to stderr in the standard
/// `file:line:col: <severity>: ...` format so build tools surface
/// it inline.
///
/// Severity controls whether the build fails:
/// - `.warning` — informational. Build proceeds normally. Used for
///   patterns Wire can work around (`@Inject` on a non-scope type,
///   `@Provides` in an unannotated extension, etc.). The default.
/// - `.error` — blocks emission. WireGen exits non-zero before
///   writing the generated file. Used for source patterns whose
///   generated code wouldn't compile or would silently produce
///   wrong results (`@Inject mutating func` on a struct, etc.).
///
/// `notes` carry related-source pointers (e.g. "also bound here"
/// secondary locations), rendered as `file:line:col: note: ...`
/// lines immediately following the diagnostic. Both follow Swift
/// compiler convention.
package struct Diagnostic: Sendable {
    package let location: SourceLocation
    package let message: String
    package let notes: [Note]
    package let severity: Severity

    package init(
        location: SourceLocation,
        message: String,
        notes: [Note] = [],
        severity: Severity = .warning
    ) {
        self.location = location
        self.message = message
        self.notes = notes
        self.severity = severity
    }

    package enum Severity: Sendable, Equatable {
        case warning
        case error
    }

    package struct Note: Sendable {
        package let location: SourceLocation
        package let message: String

        package init(location: SourceLocation, message: String) {
            self.location = location
            self.message = message
        }
    }
}

/// Two or more bindings with distinct `(type, key)` identities produce
/// the same generated accessor name (the lowerCamelCased, sanitised
/// identifier used for stored properties on `_WireGraph` and locals in
/// the bootstrap). The graph itself is unambiguous — each binding has
/// a unique identity — but codegen can't emit two `let X: T` lines with
/// the same `X`. Distinct from `DuplicateBinding` because the colliding
/// bindings are otherwise valid; only their *derived* identifier
/// collides.
package struct IdentifierCollision: Sendable {
    /// The generated accessor name shared by the colliding bindings.
    package let identifier: String
    package let bindings: [DiscoveredBinding]

    package init(identifier: String, bindings: [DiscoveredBinding]) {
        self.identifier = identifier
        self.bindings = bindings
    }
}
