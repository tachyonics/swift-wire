// Test-graph variant construction — turning a `TestingKey`'s `@BindType`
// substitutions into doubles-sourced bindings and the `_<Key>Doubles` struct the
// scope is entered with.
//
// A `@BindType(slot, Mock)` substitution rewrites the slot's binding into a
// *doubles-sourced* binding: a property-form provider keeping the slot's graph
// identity (so consumers lift to `Mock` through the same opaque-lift the real
// binding used) whose value is read from `doubles.<field>` rather than
// constructed. The `<field>` is named from the slot identity and typed to the
// concrete `Mock`; each substituted slot becomes one field on the variant's
// `_<Key>Doubles` struct. The `doubles` value rides the scope-entry thunk
// alongside the seed (`ScopeEntryEmission`), so a `@BindType`d binding resolves
// to its double per scope entry.

/// One field of a variant's `_<Key>Doubles` struct — the slot-identity-derived
/// name and the concrete `Mock` type the test supplies an instance of.
package struct DoublesField: Sendable, Equatable {
    package let name: String
    package let mockType: String

    package init(name: String, mockType: String) {
        self.name = name
        self.mockType = mockType
    }
}

/// The result of applying a variant's substitutions to a binding set: the
/// rewritten bindings (each matched slot now doubles-sourced), the doubles
/// fields the `_<Key>Doubles` struct carries, and any substitutions that matched
/// no binding (a stale `@BindType` the caller surfaces).
package struct BindTypeSubstitutionResult: Sendable {
    package let bindings: [DiscoveredBinding]
    package let doublesFields: [DoublesField]
    package let unmatched: [BindTypeSubstitution]
}

/// The `_<Key>Doubles` struct type name for a `TestingKey` reference —
/// `MyTests.testSetup` → `_MyTests_testSetupDoubles`. Dot-separated reference
/// components join with `_`, mirroring how the reference reads, and the `_`
/// prefix keeps it out of user-code's namespace like the other generated types.
package func doublesStructTypeName(forKeyReference keyReference: String) -> String {
    let components = keyReference.split(separator: ".").map(String.init)
    return "_" + components.joined(separator: "_") + "Doubles"
}

/// Rewrite the slots named by `substitutions` into doubles-sourced bindings,
/// returning the updated binding set, the doubles fields, and any unmatched
/// substitutions. A matched binding keeps its graph identity and scope but its
/// value now comes from `doubles.<field>`; its dependencies fall away (a double
/// is supplied, not constructed). Order is preserved so a scope's topological
/// shape is unchanged apart from the swapped construction source.
package func applyBindTypeSubstitutions(
    to bindings: [DiscoveredBinding],
    substitutions: [BindTypeSubstitution]
) -> BindTypeSubstitutionResult {
    var doublesFields: [DoublesField] = []
    var matchedSubstitutions: Set<Int> = []
    var updated = bindings

    for (index, binding) in bindings.enumerated() {
        guard let match = substitutions.enumerated().first(where: { substitutionMatches($0.element, binding) })
        else { continue }
        let field = doublesFieldName(for: binding)
        updated[index] = doublesSourcedBinding(replacing: binding, field: field)
        doublesFields.append(DoublesField(name: field, mockType: match.element.mockType))
        matchedSubstitutions.insert(match.offset)
    }

    let unmatched = substitutions.enumerated()
        .filter { !matchedSubstitutions.contains($0.offset) }
        .map(\.element)
    return BindTypeSubstitutionResult(bindings: updated, doublesFields: doublesFields, unmatched: unmatched)
}

/// Emit the variant's doubles struct — one field per substituted slot, plus a
/// memberwise init the harness constructs it with. `Sendable` so it crosses into
/// the scope-entry thunk. Emitted `internal` (like `_WireGraph`): the struct
/// lives in the test target beside the user's mock types, which are typically
/// themselves `internal` — a `package`/`public` field can't expose an internal
/// mock, so the struct's access is capped at the module the doubles are supplied
/// from, which is exactly where the harness builds it.
package func renderDoublesStruct(typeName: String, fields: [DoublesField]) -> String {
    var lines: [String] = ["internal struct \(typeName): Sendable {"]
    for field in fields {
        lines.append("    let \(field.name): \(field.mockType)")
    }
    let parameters = fields.map { "\($0.name): \($0.mockType)" }.joined(separator: ", ")
    lines.append("    init(\(parameters)) {")
    for field in fields {
        lines.append("        self.\(field.name) = \(field.name)")
    }
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

// MARK: - Phase 2 — the `@Scopable` cascade

/// One app-scoped hop on the path from a `@BindType`d binding up to a seeded-scope
/// root that the variant hasn't marked `@Scopable` — the guided-diagnostic subject.
/// The mocked binding is per-scope-entry under test, so a singleton consumer on the
/// path must be lifted into the scope (rebuilt per entry) to see the double; the fix
/// is `@Scopable(<hopTypeName>.self)`.
package struct UnmarkedCascadeHop: Sendable, Equatable {
    /// The mocked slot as written (`BackendRepository`) — the leaf that reaches the root through this hop.
    package let slotDisplay: String
    /// The app-scoped singleton on the path (`TodoController`) — the type the fix names.
    package let hopTypeName: String
    /// Where to point the diagnostic — the `@BindType` attribute whose slot this hop carries.
    package let location: SourceLocation

    package init(slotDisplay: String, hopTypeName: String, location: SourceLocation) {
        self.slotDisplay = slotDisplay
        self.hopTypeName = hopTypeName
        self.location = location
    }
}

/// The cascade for one seed scope under a variant: the app-singleton identities to lift into it, and any
/// app-scoped hop on a lift path the key hasn't marked `@Scopable`.
package struct CascadeResult: Sendable {
    /// App-singleton identities to reconstruct inside the seed scope — the mocked leaf(s) plus every hop
    /// on the path to a seed root. The caller moves these bindings from the app graph's borrow set into the
    /// scope's own binding set, so a lifted singleton is rebuilt per scope entry (seeing the double at `init`).
    package let liftedIdentities: Set<BindingIdentity>
    /// Hops on a lift path the key hasn't marked `@Scopable` — a guided diagnostic each, then an aborted build.
    package let unmarkedHops: [UnmarkedCascadeHop]

    package init(liftedIdentities: Set<BindingIdentity>, unmarkedHops: [UnmarkedCascadeHop]) {
        self.liftedIdentities = liftedIdentities
        self.unmarkedHops = unmarkedHops
    }
}

/// Compute the cascade for one seed scope: walk from each `@BindType`d app singleton up to the app
/// singletons the seed's roots borrow, lifting every binding on the path into the scope so a per-scope-entry
/// double reaches a singleton consumer (including at its `init`).
///
/// The mocked leaf is lifted unconditionally (`@BindType` is its acknowledgment); every *intermediate* hop
/// must be `@Scopable`d — the same explicit acknowledgment, since making a singleton per-entry can break one
/// that relies on being a singleton. An unmarked hop yields a guided diagnostic rather than a silent lift.
///
/// `appEdges` is the resolved app-graph adjacency (consumer identity → its dependency identities). The path
/// is the intersection of two reachable sets: the app singletons reachable *downward* from the seed's
/// borrow boundary, and the app singletons that can reach a mocked leaf (reachable *upward* from it). Every
/// binding in the intersection lies on some path from a seed root to a mock, so it must be lifted.
package func cascadeLift(
    seedBindings: [DiscoveredBinding],
    appSingletons: [DiscoveredBinding],
    appEdges: [BindingIdentity: [BindingIdentity]],
    substitutions: [BindTypeSubstitution],
    scopableTypeNames: Set<String>
) -> CascadeResult {
    var appProducers: [BindingIdentity: DiscoveredBinding] = [:]
    for binding in appSingletons { appProducers[binding.identity] = binding }

    // The mocked app singletons — an identity → the slot text a substitution named it by (for messages).
    var mockedSlotDisplay: [BindingIdentity: String] = [:]
    for binding in appSingletons {
        guard let match = substitutions.first(where: { substitutionMatches($0, binding) }) else { continue }
        mockedSlotDisplay[binding.identity] = match.slotType ?? match.slotKey ?? binding.boundType
    }
    guard !mockedSlotDisplay.isEmpty else { return CascadeResult(liftedIdentities: [], unmarkedHops: []) }

    // Reverse adjacency, so a mocked leaf can be walked toward its consumers.
    var reverseEdges: [BindingIdentity: [BindingIdentity]] = [:]
    for (consumer, dependencies) in appEdges {
        for dependency in dependencies { reverseEdges[dependency, default: []].append(consumer) }
    }
    let mockReaching = reachable(from: Array(mockedSlotDisplay.keys), over: reverseEdges)

    // The app singletons the seed's roots borrow directly — the boundary the lift path descends from.
    var boundary: Set<BindingIdentity> = []
    for binding in seedBindings {
        for dependency in binding.dependencies {
            let identity = bridgedDependencyIdentity(dependency, in: binding)
            if case .resolved(let resolved) = matchProducer(for: identity, in: appProducers) {
                boundary.insert(resolved)
            }
        }
    }
    let seedReachableApp = reachable(from: Array(boundary), over: appEdges)

    let liftedIdentities = seedReachableApp.intersection(mockReaching)

    // Every lifted binding that isn't a mocked leaf is an intermediate hop needing `@Scopable`.
    var unmarkedHops: [UnmarkedCascadeHop] = []
    for identity in liftedIdentities.sorted() where mockedSlotDisplay[identity] == nil {
        guard let binding = appProducers[identity], !scopableTypeNames.contains(cascadeHopName(binding)) else {
            continue
        }
        // Name a mocked leaf this hop reaches, and point the diagnostic at that leaf's `@BindType`.
        let reachedMock = reachable(from: [identity], over: appEdges).first { mockedSlotDisplay[$0] != nil }
        let slot = reachedMock.flatMap { mockedSlotDisplay[$0] } ?? mockedSlotDisplay.values.sorted().first ?? ""
        let location =
            substitutions.first(where: { ($0.slotType ?? $0.slotKey) == slot })?.location ?? binding.location
        unmarkedHops.append(
            UnmarkedCascadeHop(slotDisplay: slot, hopTypeName: cascadeHopName(binding), location: location)
        )
    }

    return CascadeResult(liftedIdentities: liftedIdentities, unmarkedHops: unmarkedHops)
}

/// The transitive closure reachable from `roots` over `edges` (roots included). A plain BFS the cascade
/// runs in both directions — downward over the app adjacency, upward over its reverse.
private func reachable(
    from roots: [BindingIdentity],
    over edges: [BindingIdentity: [BindingIdentity]]
) -> Set<BindingIdentity> {
    var visited: Set<BindingIdentity> = []
    var queue = roots
    while let identity = queue.popLast() {
        guard visited.insert(identity).inserted else { continue }
        queue.append(contentsOf: edges[identity] ?? [])
    }
    return visited
}

/// The name a cascade hop is matched and messaged by — a `@Singleton`/`@Scoped` type's own name (what
/// `@Scopable(X.self)` references), or a provider's stripped bound type as a fallback.
private func cascadeHopName(_ binding: DiscoveredBinding) -> String {
    if case .scopeBound(let scopeBound) = binding { return scopeBound.typeName }
    return strippedSlotType(binding.boundType)
}

/// The substitutions whose slot matches no binding in `bindings` — a stale or mistyped `@BindType` the
/// caller diagnoses. Distinct from `applyBindTypeSubstitutions`'s per-set `unmatched`: here the caller
/// passes the whole production binding set (app singletons + every seed scope), so a slot that exists
/// *somewhere* isn't reported even when a particular scope doesn't touch it.
package func unmatchedSubstitutions(
    _ substitutions: [BindTypeSubstitution],
    against bindings: [DiscoveredBinding]
) -> [BindTypeSubstitution] {
    substitutions.filter { substitution in
        !bindings.contains(where: { substitutionMatches(substitution, $0) })
    }
}

/// The guided diagnostic for one unmarked cascade hop — names the mocked leaf, the singleton it reaches the
/// root through, and the exact `@Scopable` to add.
package func unmarkedCascadeHopDiagnostic(_ hop: UnmarkedCascadeHop) -> Diagnostic {
    Diagnostic(
        location: hop.location,
        message:
            "\(hop.slotDisplay) is bound per-scope-entry under test, but reaches the scope root through "
            + "singleton '\(hop.hopTypeName)'. Add @Scopable(\(hop.hopTypeName).self) to allow it to be "
            + "lifted into the scope under test.",
        severity: .error
    )
}

/// The diagnostic for a `@BindType` substitution whose slot no binding produces — a stale or mistyped
/// substitution, surfaced rather than silently discarded.
package func unmatchedBindTypeDiagnostic(_ substitution: BindTypeSubstitution) -> Diagnostic {
    let slot = substitution.slotType ?? substitution.slotKey ?? "?"
    return Diagnostic(
        location: substitution.location,
        message:
            "@BindType(\(slot), \(substitution.mockType).self) substitutes a slot no binding under test "
            + "produces — check the slot type or key.",
        severity: .error
    )
}

/// Whether a `@BindType` substitution names the slot `binding` produces. The
/// type form matches an unkeyed binding whose bound type (opaque prefix
/// stripped) equals the slot; the keyed form matches a binding carrying the
/// slot's key. Mirrors how `@Provides` / `@Replaces` identify their slot.
private func substitutionMatches(_ substitution: BindTypeSubstitution, _ binding: DiscoveredBinding) -> Bool {
    if let slotType = substitution.slotType {
        return binding.keyIdentifier == nil && strippedSlotType(binding.boundType) == slotType
    }
    if let slotKey = substitution.slotKey {
        return binding.keyIdentifier == slotKey
    }
    return false
}

/// The doubles field name for a matched slot — the slot-identity property name,
/// derived from the binding's bound type (opaque prefix stripped so `some
/// BackendRepository` and a concrete `BackendRepository` share the field
/// `backendRepository`) and its key.
private func doublesFieldName(for binding: DiscoveredBinding) -> String {
    identifierName(forType: strippedSlotType(binding.boundType), key: binding.keyIdentifier)
}

/// The doubles-sourced replacement for a matched binding: a property-form
/// provider keeping the binding's graph identity (bound type + key + scope) so
/// consumers resolve it exactly as before, but sourcing its value from
/// `doubles.<field>` and carrying no construction dependencies.
private func doublesSourcedBinding(replacing binding: DiscoveredBinding, field: String) -> DiscoveredBinding {
    let scopeKey: ScopeKey?
    switch binding {
    case .scopeBound(let scopeBound): scopeKey = scopeBound.scopeKey
    case .provider(let provider): scopeKey = provider.scopeKey
    case .aggregate: scopeKey = nil
    }
    return .provider(
        DiscoveredProvider(
            boundType: binding.boundType,
            accessPath: "doubles.\(field)",
            form: .property,
            dependencies: [],
            genericParameterNames: [],
            location: binding.location,
            keyIdentifier: binding.keyIdentifier,
            accessLevel: binding.accessLevel,
            scopeKey: scopeKey,
            originModule: binding.originModule
        )
    )
}

/// Strip a leading `some `/`any ` from a bound type so a slot named
/// `BackendRepository` matches a binding keyed `some BackendRepository`.
private func strippedSlotType(_ boundType: String) -> String {
    for prefix in ["some ", "any "] where boundType.hasPrefix(prefix) {
        return String(boundType.dropFirst(prefix.count))
    }
    return boundType
}
