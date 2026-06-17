// Discovery data types for iteration 5β multibindings — the key
// declarations and the contributions that fan into them. Extracted from
// `Discovery.swift` to keep that file under the `file_length` cap; the
// `contributions` fields and accessor live on the producer types in
// `Discovery.swift` itself. See
// `Documentation/Notes/MultibindingsImplementationPlan.md`.

/// Which multibinding flavour a key declaration names. Drives the
/// aggregate's codegen shape and the build plugin's per-flavour
/// parameter-validity checks.
package enum MultibindingKeyFlavour: Sendable, Equatable {
    /// `CollectedKey<Element>` — aggregates contributors into `[Element]`.
    case collected
    /// `MappedKey<Key, Value>` — aggregates into `[Key: Value]`.
    case mapped
    /// `BuilderKey<Builder>` — folds contributors through `Builder`.
    case builder
}

/// One multibinding key declaration found in source — a `static let`
/// (or module-scope `let`) whose type is `CollectedKey<…>`,
/// `MappedKey<…>`, or `BuilderKey<…>`. Unlike single-binding
/// `BindingKey`s (which Wire never reads — the compiler enforces their
/// type via generated `_check`s), multibinding keys are read producer-
/// side: the aggregate takes its element/value/result type and its
/// flavour from this declaration. See
/// `Documentation/Notes/MultibindingsImplementationPlan.md`.
package struct DiscoveredMultibindingKey: Sendable, Equatable {
    /// Canonical reference text used to match `@Contributes(to:)` and
    /// aggregate `@Inject` sites against this declaration — `App.services`
    /// for a `static let services` on (an extension of) `App`, or just
    /// `services` for a module-scope key. Same string-keyed discipline as
    /// today's keyed bindings.
    package let keyReference: String
    package let flavour: MultibindingKeyFlavour
    /// The flavour's generic argument(s), verbatim: `[Element]` for
    /// collected, `[Key, Value]` for mapped, `[Builder]` for builder.
    /// Empty when the key is declared without explicit generics
    /// (`= CollectedKey()` and no annotation) — the producer-side type is
    /// then unknown and downstream steps must diagnose it.
    package let typeArguments: [String]
    package let location: SourceLocation
    /// Effective access — the declaration's own modifier folded with
    /// every enclosing type's access. Drives the visibility-gated
    /// empty/dead-key diagnostics (and, later, the cross-module
    /// threshold).
    package let accessLevel: AccessLevel

    package init(
        keyReference: String,
        flavour: MultibindingKeyFlavour,
        typeArguments: [String],
        location: SourceLocation,
        accessLevel: AccessLevel
    ) {
        self.keyReference = keyReference
        self.flavour = flavour
        self.typeArguments = typeArguments
        self.location = location
        self.accessLevel = accessLevel
    }
}

/// One `@Contributes(to:)` annotation found on a producer. A producer
/// keeps its own binding identity *and* carries a list of these (a
/// contributor may target several keys via repeated `@Contributes`, which
/// Swift permits). The fan-in pass (Step 4) groups contributions across
/// the module by `keyReference` and matches them to the discovered key
/// declaration.
package struct Contribution: Sendable, Equatable {
    /// Reference text of the targeted multibinding key, matched against
    /// `DiscoveredMultibindingKey.keyReference` — `App.services`.
    package let keyReference: String
    /// `withOrder:` rank among the key's contributors, if specified.
    /// `nil` means unranked. Valid on `CollectedKey`/`BuilderKey`
    /// contributions (the build plugin enforces flavour validity).
    package let order: Int?
    /// `atKey:` expression rendered verbatim — the map entry's key for a
    /// `MappedKey` contribution. `nil` for collected/builder
    /// contributions.
    package let mapKeyExpression: String?
    /// Position of the `@Contributes` attribute — what a per-contribution
    /// diagnostic (duplicate `atKey:`, mixed `withOrder:`) navigates to.
    package let location: SourceLocation

    package init(
        keyReference: String,
        order: Int? = nil,
        mapKeyExpression: String? = nil,
        location: SourceLocation
    ) {
        self.keyReference = keyReference
        self.order = order
        self.mapKeyExpression = mapKeyExpression
        self.location = location
    }
}
