/// The binding-identity and optional-matching layer: how a dependency's
/// type is canonicalised into a graph slot, and how a dependency is
/// matched to a producer under asymmetric optional promotion. Extracted
/// from `Graph.swift` so the resolver's matching rule lives in one place.
/// The model is pinned in `OptionalMatchingAndCycles.md`.

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
    /// No producer satisfies the dependency.
    case missing
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
    }
    return .missing
}
