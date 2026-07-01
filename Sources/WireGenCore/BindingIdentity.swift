/// The binding-identity and optional-matching layer: how a dependency's
/// type is canonicalised into a graph slot, and how a dependency is
/// matched to a producer under asymmetric optional promotion.

/// Strip whitespace from a type expression so cosmetic variations
/// resolve to the same graph slot. `Router<X, Y>` and `Router<X,Y>`
/// both canonicalise to `Router<X,Y>`; `Dictionary<String, [Int]>` and
/// `Dictionary<String,[Int]>` both canonicalise to
/// `Dictionary<String,[Int]>`. The M0 spike 3 finding: SwiftSyntax's
/// `trimmedDescription` preserves internal whitespace verbatim, so two
/// users writing the same type with different formatting would
/// previously fail to resolve against each other.
///
/// Codegen continues to use the binding's original `boundType` text
/// (whatever the user wrote) — only the *identity* used for graph
/// lookup is canonicalised. The generated file keeps idiomatic
/// formatting; only the resolution layer normalises.
package func canonicalTypeName(_ raw: String) -> String {
    raw.filter { !$0.isWhitespace }
}

/// Split a canonical (whitespace-stripped) type into its base and whether
/// it carried a single top-level optional layer. `T?` and `T!` (IUO) both
/// yield `(base: "T", isOptional: true)`; `T` yields `(base: "T", false)`.
/// Only the outermost `?`/`!` is removed — one level; nested optionals
/// effectively never appear in a binding type (see
/// `OptionalMatchingAndCycles.md`, "strip at most one `?`"). A trailing
/// `?`/`!` is always the top-level optional: a generic like `Foo<Bar?>`
/// ends in `>`, not `?`.
func optionalityStripped(_ canonical: String) -> (base: String, isOptional: Bool) {
    if canonical.hasSuffix("?") || canonical.hasSuffix("!") {
        return (String(canonical.dropLast()), true)
    }
    return (canonical, false)
}

/// Compound identity for a binding — `(base, isOptional, keyIdentifier?)`.
/// `base` is the canonical inner type with at most one top-level optional
/// layer removed; `isOptional` records whether that layer was present
/// (`T?` or `T!`). Splitting optionality out of the type string — rather
/// than folding `?` into it — lets the matcher promote a `T` producer to
/// satisfy a `T?` consumer (and forbid the reverse) as a structural rule.
/// See `OptionalMatchingAndCycles.md`.
///
/// Two bindings with the same `(base, isOptional)` but different `key`s
/// coexist; same `base`, same `isOptional`, same `key` are duplicates.
/// Unkeyed deps (`key == nil`) match only unkeyed bindings; keyed deps
/// match only same-key bindings — keys partition the binding space
/// (Dagger semantics).
struct BindingIdentity: Hashable, Comparable {
    let base: String
    let isOptional: Bool
    let key: String?

    /// The type as written for diagnostics — `base` with the optional
    /// layer re-applied (`T` or `T?`). IUO (`T!`) renders as `T?`.
    var displayType: String { isOptional ? base + "?" : base }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.base != rhs.base { return lhs.base < rhs.base }
        // Non-optional sorts before its optional sibling.
        if lhs.isOptional != rhs.isOptional { return !lhs.isOptional }
        // Unkeyed sorts before any keyed identity; among keyed, sort
        // by key text. `nil` and `""` would otherwise compare as
        // equivalent under a `?? ""` coalesce while being distinct
        // under the auto-synthesised `Hashable`, leading to undefined
        // sort order between them if both ever appeared in the same
        // collection.
        switch (lhs.key, rhs.key) {
        case (nil, nil): return false
        case (nil, _?): return true
        case (_?, nil): return false
        case let (lhsKey?, rhsKey?): return lhsKey < rhsKey
        }
    }
}

extension DiscoveredBinding {
    var identity: BindingIdentity {
        let split = optionalityStripped(canonicalTypeName(boundType))
        return BindingIdentity(base: split.base, isOptional: split.isOptional, key: keyIdentifier)
    }
}

extension DependencyParameter {
    var identity: BindingIdentity {
        let split = optionalityStripped(canonicalTypeName(type))
        return BindingIdentity(base: split.base, isOptional: split.isOptional, key: keyIdentifier)
    }
}

/// Outcome of resolving one dependency identity against the producer
/// set, applying asymmetric optional promotion (see
/// `OptionalMatchingAndCycles.md`): a `T?` dependency is satisfied by an
/// exact `T?` producer or, failing that, a promoted `T` producer; a `T`
/// dependency is satisfied only by an exact `T` producer — a `T?`
/// producer can never satisfy a non-optional consumer.
enum DependencyMatch {
    /// Resolved to the producer with this identity. Under promotion this
    /// differs from the dependency's own identity: a `T?` dependency
    /// resolves to the `T` producer.
    case resolved(BindingIdentity)
    /// No producer satisfies the dependency. The associated hint, when
    /// present, explains an *optionality* mismatch so the missing-binding
    /// diagnostic can guide the fix.
    case missing(OptionalMismatchHint?)
}

/// An optionality-specific reason a dependency went unmatched, surfaced
/// as a `note:` beneath the missing-binding error. See
/// `OptionalMatchingAndCycles.md`.
package enum OptionalMismatchHint: Sendable, Equatable {
    /// A non-optional dependency where a producer of its *optional* form
    /// exists — the asymmetry (`T?` can't satisfy `T`). The fix is to
    /// change the consumer to `T?` or have the producer return `T`; the
    /// renderer derives the type from the dependency.
    case optionalProducerCannotSatisfyNonOptional
    /// An optional dependency with no producer at all — a reminder that
    /// Wire never injects nil for an absent binding, so even an optional
    /// dependency needs an explicit producer.
    case optionalNeedsExplicitProducer
}

/// Translate a dependency to the identity it resolves against, applying the
/// constrained-parameter bridge (Rule 2 of the opaque model): when `binding` is
/// a lift node (`@Singleton(as:)` or a determined generic `@Singleton`) and
/// `dependency` is one of its bare generic parameters constrained to a protocol
/// `C`, the dependency resolves to the `some C` binding. Every other dependency
/// keeps its own identity. This is the single conformance-*aware* step — it
/// reads the declared constraint, it does not search conformers — and it only
/// fires for lift nodes, so a generic `@Provides func` template's parameters
/// still specialise as before.
/// Protocols that don't identify a single binding. A generic parameter
/// constrained *only* to these isn't "determined" — `some Sendable` (etc.) is
/// never a meaningful graph identity, so such a parameter is effectively
/// unconstrained.
let markerConstraintProtocols: Set<String> = ["Sendable", "AnyObject", "Any"]

/// Whether a generic-parameter constraint identifies a binding: `true` if, after
/// dropping marker protocols, at least one protocol remains. `TaskRepository` and
/// `DBTable & Sendable` determine; `Sendable` alone does not.
func constraintIsDetermining(_ constraint: String) -> Bool {
    constraint
        .split(separator: "&")
        .map { canonicalTypeName(String($0)) }
        .contains { !markerConstraintProtocols.contains($0) }
}

func bridgedDependencyIdentity(
    _ dependency: DependencyParameter,
    in binding: DiscoveredBinding
) -> BindingIdentity {
    guard binding.isLiftNode,
        let constraint = binding.genericParameterConstraints[canonicalTypeName(dependency.type)]
    else { return dependency.identity }
    let split = optionalityStripped(canonicalTypeName("some \(constraint)"))
    return BindingIdentity(base: split.base, isOptional: split.isOptional, key: dependency.keyIdentifier)
}

func matchProducer(
    for dependency: BindingIdentity,
    in producers: [BindingIdentity: DiscoveredBinding]
) -> DependencyMatch {
    if producers[dependency] != nil { return .resolved(dependency) }
    // Promotion flows one way only: a `T?` consumer may borrow a `T`
    // producer. A non-optional consumer never borrows a `T?` producer.
    if dependency.isOptional {
        let promoted = BindingIdentity(base: dependency.base, isOptional: false, key: dependency.key)
        if producers[promoted] != nil { return .resolved(promoted) }
        // Optional dep, nothing matched: neither `T?` nor `T` is bound.
        return .missing(.optionalNeedsExplicitProducer)
    }
    // Non-optional dep: if only the optional form is bound, that's the
    // asymmetry — flag it so the diagnostic can say why and how to fix.
    let optionalProducer = BindingIdentity(base: dependency.base, isOptional: true, key: dependency.key)
    if producers[optionalProducer] != nil {
        return .missing(.optionalProducerCannotSatisfyNonOptional)
    }
    return .missing(nil)
}
