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
/// Protocol-composition members are additionally sorted, so
/// `DBTable & Sendable` and `Sendable & DBTable` name the same slot. The
/// two spellings are one type to Swift, so a producer written in one
/// order and a consumer constraint written in the other must resolve
/// against each other; without sorting they are distinct identities and
/// the consumer reports a missing binding naming a type the user reads
/// as the one they bound. A leading `some`/`any` stays in front of the
/// sorted members.
///
/// Codegen continues to use the binding's original `boundType` text
/// (whatever the user wrote) — only the *identity* used for graph
/// lookup is canonicalised. The generated file keeps idiomatic
/// formatting; only the resolution layer normalises.
package func canonicalTypeName(_ raw: String) -> String {
    let (qualifier, body) = splitLeadingTypeQualifier(raw)
    let members = topLevelCompositionMembers(body)
    guard members.count > 1 else { return qualifier + whitespaceStripped(body) }
    return qualifier + members.map(whitespaceStripped).sorted().joined(separator: "&")
}

private func whitespaceStripped(_ text: Substring) -> String {
    String(text.filter { !$0.isWhitespace })
}

/// Split a leading `some`/`any` qualifier off a type expression:
/// `"some P & Q"` → `("some", " P & Q")`. The qualifier must be followed by
/// whitespace, so a type named `someThing` keeps its whole name. Anything else
/// yields an empty qualifier and the leading-whitespace-trimmed expression.
private func splitLeadingTypeQualifier(_ raw: String) -> (qualifier: String, body: Substring) {
    let body = raw.drop { $0.isWhitespace }
    for qualifier in ["some", "any"] where body.hasPrefix(qualifier) {
        let rest = body.dropFirst(qualifier.count)
        if let next = rest.first, next.isWhitespace { return (qualifier, rest) }
    }
    return ("", body)
}

/// Split a type expression at its depth-0 `&`s, keeping nested compositions
/// (`Box<A & B>`) and parenthesised ones (`(A & B)?`) intact as one member. The
/// `>` of a function arrow doesn't close a generic argument list, so it doesn't
/// decrement the depth. Malformed input yields whatever was accumulated — the
/// build plugin trusts its inputs to be parsed Swift type expressions.
private func topLevelCompositionMembers(_ body: Substring) -> [Substring] {
    var members: [Substring] = []
    var depth = 0
    var memberStart = body.startIndex
    var previous: Character?
    for index in body.indices {
        let character = body[index]
        switch character {
        case "<", "(", "[":
            depth += 1
        case ">" where previous != "-", ")", "]":
            depth = max(0, depth - 1)
        case "&" where depth == 0:
            members.append(body[memberStart..<index])
            memberStart = body.index(after: index)
        default:
            break
        }
        previous = character
    }
    members.append(body[memberStart...])
    return members
}

/// Split a type expression into its maximal identifier runs (`[A-Za-z0-9_]+`), in written order:
/// `Foo<Bar<Baz>>` → `["Foo", "Bar", "Baz"]`. Punctuation (`<`, `,`, `>`, `?`, `.`) delimits tokens.
func identifierTokens(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in text {
        if character.isLetter || character.isNumber || character == "_" {
            current.append(character)
        } else if !current.isEmpty {
            tokens.append(current)
            current = ""
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

/// Whether the generic parameter `parameter` appears as a generic *argument* — an identifier token
/// after the base type — within `type` (e.g. `Element` in `Box<Element>`). Swift has no higher-kinded
/// generics, so a parameter can never be a base type; a match anywhere after the first token is
/// therefore a generic-argument use. Token-level, so a substring like `ElementKind` never matches. This
/// is what lets a binding generic over `T` that depends on `Box<T>` earn lift-node status (transitive
/// lift) rather than only one that depends on the bare `T`.
func parameterAppearsAsGenericArgument(_ parameter: String, in type: String) -> Bool {
    identifierTokens(type).dropFirst().contains(parameter)
}

/// Rewrite each identifier token in `type` that is a key of `substitutions` to its value, leaving
/// punctuation and every other token (including the base type) intact:
/// `Box<Element>` with `["Element": "someP"]` → `Box<someP>`.
func substitutingIdentifierTokens(_ type: String, _ substitutions: [String: String]) -> String {
    var result = ""
    var current = ""
    func flush() {
        if !current.isEmpty {
            result += substitutions[current] ?? current
            current = ""
        }
    }
    for character in type {
        if character.isLetter || character.isNumber || character == "_" {
            current.append(character)
        } else {
            flush()
            result.append(character)
        }
    }
    flush()
    return result
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

/// A type's promotable qualifier — the leading `some`/`any`, or neither.
/// Split out of the identity string for the same reason `isOptional` is: the
/// matcher promotes across it structurally (a `some P` producer satisfies an
/// `any P` consumer, never the reverse), and deciding that on the raw text
/// rather than on a whitespace-stripped prefix keeps a type named `anyThing`
/// from being read as `any Thing`. See `OpaqueTypesSupport.md`, rule 3.
package enum TypeQualifier: String, Hashable, Comparable, Sendable {
    case none = ""
    case some = "some"
    case any = "any"

    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Drop a single top-level optional layer from a type *as written*, preserving
/// the user's spacing: `any Logger?` → `any Logger`. Used for the existential
/// alias's annotation, where the spelling is emitted rather than compared.
func optionalLayerDropped(_ raw: String) -> String {
    if raw.hasSuffix("?") || raw.hasSuffix("!") { return String(raw.dropLast()) }
    return raw
}

/// Compound identity for a binding — `(qualifier, base, isOptional, keyIdentifier?)`.
/// `base` is the canonical inner type with the leading `some`/`any` and at most
/// one top-level optional layer removed; `qualifier` and `isOptional` record what
/// was removed. Splitting both out of the type string — rather than folding them
/// into it — lets the matcher promote a `T` producer to satisfy a `T?` consumer,
/// and a `some P` producer to satisfy an `any P` consumer (forbidding both
/// reverses), as structural rules. See `OptionalMatchingAndCycles.md` and
/// `OpaqueTypesSupport.md`.
///
/// Two bindings with the same `(qualifier, base, isOptional)` but different
/// `key`s coexist; all four the same are duplicates. Unkeyed deps
/// (`key == nil`) match only unkeyed bindings; keyed deps match only same-key
/// bindings — keys partition the binding space (Dagger semantics).
package struct BindingIdentity: Hashable, Comparable, Sendable {
    package let qualifier: TypeQualifier
    package let base: String
    package let isOptional: Bool
    package let key: String?

    package init(qualifier: TypeQualifier = .none, base: String, isOptional: Bool, key: String?) {
        self.qualifier = qualifier
        self.base = base
        self.isOptional = isOptional
        self.key = key
    }

    /// The type as written for diagnostics and for deriving generated
    /// identifiers — the qualifier and optional layer re-applied to `base`,
    /// in the same whitespace-free spelling canonicalisation produces
    /// (`someP`, `anyP?`). IUO (`T!`) renders as `T?`.
    package var displayType: String { qualifier.rawValue + base + (isOptional ? "?" : "") }

    /// The same identity read through a different qualifier — how the matcher
    /// spells a promotion target. `any P` asks for `.some` and finds the opaque
    /// binding that satisfies it.
    func qualified(_ qualifier: TypeQualifier) -> Self {
        Self(qualifier: qualifier, base: base, isOptional: isOptional, key: key)
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.base != rhs.base { return lhs.base < rhs.base }
        if lhs.qualifier != rhs.qualifier { return lhs.qualifier < rhs.qualifier }
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

/// Split a raw type expression into the components the matcher promotes over:
/// the leading `some`/`any`, the canonical remainder, and whether a top-level
/// optional layer was present. `any P & Q` → `(.any, "P&Q", false)`;
/// `some P?` → `(.some, "P", true)`; `Foo<some P>` → `(.none, "Foo<someP>", false)`,
/// since only a *leading* qualifier is split — a nested one stays part of the
/// structural base, which is what a lift node's identity is built from.
func identityComponents(
    _ raw: String
) -> (qualifier: TypeQualifier, base: String, isOptional: Bool) {
    let (qualifier, body) = splitLeadingTypeQualifier(raw)
    let split = optionalityStripped(canonicalTypeName(String(body)))
    return (TypeQualifier(rawValue: qualifier) ?? .none, split.base, split.isOptional)
}

extension DiscoveredBinding {
    package var identity: BindingIdentity {
        let components = identityComponents(boundType)
        return BindingIdentity(
            qualifier: components.qualifier,
            base: components.base,
            isOptional: components.isOptional,
            key: keyIdentifier
        )
    }
}

extension DependencyParameter {
    var identity: BindingIdentity {
        let components = identityComponents(type)
        return BindingIdentity(
            qualifier: components.qualifier,
            base: components.base,
            isOptional: components.isOptional,
            key: keyIdentifier
        )
    }
}

/// Outcome of resolving one dependency identity against the producer
/// set, applying asymmetric optional promotion (see
/// `OptionalMatchingAndCycles.md`): a `T?` dependency is satisfied by an
/// exact `T?` producer or, failing that, a promoted `T` producer; a `T`
/// dependency is satisfied only by an exact `T` producer — a `T?`
/// producer can never satisfy a non-optional consumer.
enum DependencyMatch: Equatable {
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

/// A `some P` producer reached by an `any P` consumer through rule 3's qualifier
/// promotion. Recorded during resolution and surfaced to codegen, which emits one
/// *existential alias* local per promoted producer — `let anyP: any P = someP` —
/// so the value boxes once per scope body rather than once per consumption site,
/// and so consumers find a local under the name `renderArguments` derives from
/// their own `any P` dependency. Without the alias the two sides disagree:
/// `some P` and `any P` sanitise to different identifiers (`someP` vs `anyP`),
/// unlike `T` and `T?`, which is why optional promotion needs no such machinery.
package struct ExistentialPromotion: Hashable, Sendable {
    package let consumer: BindingIdentity
    package let producer: BindingIdentity
    /// The existential as the consumer wrote it, with any optional layer
    /// dropped — the alias's type annotation. A non-optional alias also
    /// satisfies an `any P?` consumer, so one alias serves both spellings.
    package let existentialType: String

    package init(consumer: BindingIdentity, producer: BindingIdentity, existentialType: String) {
        self.consumer = consumer
        self.producer = producer
        self.existentialType = existentialType
    }

    /// The alias local's name — the same one a consumer's `any P` dependency
    /// renders at its argument site.
    package var aliasName: String {
        identifierName(forType: producer.qualified(.any).nonOptionalDisplay, key: producer.key)
    }

    /// The producer's own local name — the alias's right-hand side wherever the
    /// producer is in scope under it.
    package var producerLocalName: String {
        identifierName(forType: producer.displayType, key: producer.key)
    }
}

extension BindingIdentity {
    /// `displayType` with the optional layer dropped — the spelling an alias
    /// local is named and typed from.
    var nonOptionalDisplay: String { qualifier.rawValue + base }

    /// This identity with `some` folded into `any` — the slot two qualifier
    /// variants of one protocol share. Two bindings landing on the same
    /// normalised identity are duplicates; `.none` is left alone, since Wire
    /// can't tell a bare `P` protocol name from a concrete type syntactically.
    var qualifierNormalised: Self {
        qualifier == .some ? qualified(.any) : self
    }
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
    guard binding.isLiftNode else { return dependency.identity }
    let canonicalDependencyType = canonicalTypeName(dependency.type)

    // Rule 2a — the dependency IS a bare generic parameter: resolve to its `some C` binding.
    if let constraint = binding.genericParameterConstraints[canonicalDependencyType] {
        let components = identityComponents("some \(constraint)")
        return BindingIdentity(
            qualifier: components.qualifier,
            base: components.base,
            isOptional: components.isOptional,
            key: dependency.keyIdentifier
        )
    }

    // Rule 2b (transitive lift) — the dependency is a parameterised type whose generic arguments
    // include the binding's determined parameters (`Box<Element>`); substitute each with `some C`,
    // yielding the wrapped lift node's structural identity (`Box<some P>`) so the dependency resolves
    // against it.
    var substitutions: [String: String] = [:]
    for (parameter, constraint) in binding.genericParameterConstraints
    where constraintIsDetermining(constraint)
        && parameterAppearsAsGenericArgument(parameter, in: canonicalDependencyType)
    {
        substitutions[parameter] = canonicalTypeName("some \(constraint)")
    }
    if !substitutions.isEmpty {
        let split = optionalityStripped(substitutingIdentifierTokens(canonicalDependencyType, substitutions))
        return BindingIdentity(base: split.base, isOptional: split.isOptional, key: dependency.keyIdentifier)
    }

    return dependency.identity
}

/// The identities a dependency will accept, in precedence order — itself first,
/// then each promotion the closed set allows. Both promotions flow one way only:
/// a `T?` consumer may borrow a `T` producer, and an `any P` consumer may borrow
/// a `some P` producer (the underlying value boxes into the existential at the
/// consumption site). Neither reverse is ever offered — a `T?` producer can't
/// satisfy `T`, and an `any P` producer has erased the single underlying type
/// `some P` requires. When a dependency is both optional and existential all four
/// combinations are tried, exact-most first.
private func acceptableProducers(for dependency: BindingIdentity) -> [BindingIdentity] {
    var candidates = [dependency]
    if dependency.isOptional { candidates.append(dependency.nonOptional) }
    if dependency.qualifier == .any {
        candidates.append(dependency.qualified(.some))
        if dependency.isOptional { candidates.append(dependency.qualified(.some).nonOptional) }
    }
    return candidates
}

extension BindingIdentity {
    fileprivate var nonOptional: Self {
        Self(qualifier: qualifier, base: base, isOptional: false, key: key)
    }

    fileprivate var optional: Self {
        Self(qualifier: qualifier, base: base, isOptional: true, key: key)
    }
}

func matchProducer(
    for dependency: BindingIdentity,
    in producers: [BindingIdentity: DiscoveredBinding]
) -> DependencyMatch {
    for candidate in acceptableProducers(for: dependency) where producers[candidate] != nil {
        return .resolved(candidate)
    }
    if dependency.isOptional {
        // Optional dep, nothing matched: neither `T?` nor `T` is bound.
        return .missing(.optionalNeedsExplicitProducer)
    }
    // Non-optional dep: if only the optional form is bound, that's the
    // asymmetry — flag it so the diagnostic can say why and how to fix.
    if producers[dependency.optional] != nil {
        return .missing(.optionalProducerCannotSatisfyNonOptional)
    }
    return .missing(nil)
}
