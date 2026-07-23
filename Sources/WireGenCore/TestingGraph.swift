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
