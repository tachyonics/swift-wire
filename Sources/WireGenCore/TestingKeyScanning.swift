import SwiftSyntax

// Recognition of `TestingKey` declarations and their attached `@BindType`
// markers — the test-graph-variant sibling of `BindingKeyScanning`. Same
// syntax-only discipline and `(enclosingType, member)` reference
// reconstruction; the substitutions are read off the stacked `@BindType`
// attributes the way `@Provides(key)` / `@Replaces` read their arguments.
//
// A `TestingKey` static carries zero or more `@BindType(slot, Mock)` markers,
// each substituting one slot's type in the variant. Discovery groups them by
// the key they attach to; the graph pass turns each `(slot, Mock)` into a
// doubles-sourced binding and emits the variant's `_<Key>Doubles` struct.

/// One `@BindType(slot, Mock)` substitution read off a `TestingKey` static.
/// The slot is named either by a metatype (`Repo.self` → `slotType`) or by a
/// binding key (`Repo.primary` → `slotKey`), mirroring `@Provides` /
/// `@Replaces`; exactly one of the two is non-nil.
package struct BindTypeSubstitution: Sendable, Equatable {
    /// The slot's type expression for the type form `@BindType(Repo.self, …)`
    /// — `"Repo"` — or `nil` for the keyed form.
    package let slotType: String?
    /// The slot's key reference for the keyed form `@BindType(Repo.primary, …)`
    /// — `"Repo.primary"` — or `nil` for the type form.
    package let slotKey: String?
    /// The concrete mock type the slot is bound to in the variant — the second
    /// argument's metatype base (`MockRepo` for `MockRepo.self`).
    package let mockType: String
    package let location: SourceLocation

    package init(slotType: String?, slotKey: String?, mockType: String, location: SourceLocation) {
        self.slotType = slotType
        self.slotKey = slotKey
        self.mockType = mockType
        self.location = location
    }
}

/// One `@Scopable(X.self)` marker read off a `TestingKey` static — an app-scoped
/// binding the variant permits the cascade to lift into a seeded scope. The
/// `typeName` is the marked type's name (`TodoController` for `TodoController.self`),
/// matched against a lifted binding's type name during the cascade walk.
package struct ScopableMarker: Sendable, Equatable {
    package let typeName: String
    package let location: SourceLocation

    package init(typeName: String, location: SourceLocation) {
        self.typeName = typeName
        self.location = location
    }
}

/// One `TestingKey` declaration found in source — a `static let` (or
/// module-scope `let`) initialised with `TestingKey()` (or annotated
/// `: TestingKey`), together with the `@BindType` substitutions and `@Scopable`
/// markers stacked on it.
package struct DiscoveredTestingKey: Sendable, Equatable {
    /// Canonical reference text — `MyTests.testSetup` for a `static let
    /// testSetup` on `MyTests`, or just `testSetup` for a module-scope key.
    /// The variant's doubles-struct type name derives from it.
    package let keyReference: String
    /// The substitutions the variant applies, in source (top-to-bottom
    /// attribute) order.
    package let substitutions: [BindTypeSubstitution]
    /// The app-scoped bindings this variant permits the cascade to lift into a
    /// seeded scope, in source (top-to-bottom attribute) order.
    package let scopables: [ScopableMarker]
    package let location: SourceLocation
    package let accessLevel: AccessLevel
    package let originModule: String

    package init(
        keyReference: String,
        substitutions: [BindTypeSubstitution],
        scopables: [ScopableMarker] = [],
        location: SourceLocation,
        accessLevel: AccessLevel,
        originModule: String
    ) {
        self.keyReference = keyReference
        self.substitutions = substitutions
        self.scopables = scopables
        self.location = location
        self.accessLevel = accessLevel
        self.originModule = originModule
    }
}

/// Recognise a `TestingKey` declaration — a `let`/`static let` whose type is
/// `TestingKey` — and read the `@BindType` substitutions attached to it.
/// Returns `nil` for any declaration that doesn't name `TestingKey`.
func testingKey(
    from node: VariableDeclSyntax,
    enclosingTypeNames: [String],
    enclosingAccessLevels: [AccessLevel],
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> DiscoveredTestingKey? {
    guard node.bindings.count == 1, let binding = node.bindings.first else { return nil }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    guard
        namesTestingKey(
            annotation: binding.typeAnnotation?.type,
            initializer: binding.initializer?.value
        )
    else { return nil }

    let keyReference = (enclosingTypeNames + [pattern.identifier.text]).joined(separator: ".")
    let effectiveAccess =
        enclosingAccessLevels
        .reduce(accessLevel(from: node.modifiers)) { $0.mostRestrictive(with: $1) }

    let substitutions = node.attributes.compactMap { element -> BindTypeSubstitution? in
        guard case .attribute(let attribute) = element,
            attribute.attributeName.trimmedDescription == "BindType"
        else { return nil }
        return bindTypeSubstitution(from: attribute, sourcePath: sourcePath, converter: converter)
    }

    let scopables = node.attributes.compactMap { element -> ScopableMarker? in
        guard case .attribute(let attribute) = element,
            attribute.attributeName.trimmedDescription == "Scopable"
        else { return nil }
        return scopableMarker(from: attribute, sourcePath: sourcePath, converter: converter)
    }

    return DiscoveredTestingKey(
        keyReference: keyReference,
        substitutions: substitutions,
        scopables: scopables,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        accessLevel: effectiveAccess,
        originModule: module
    )
}

/// Whether a declaration's type annotation or constructor-call initialiser names
/// `TestingKey`. Mirrors `BindingKeyScanning`'s recognition, minus the generic
/// argument list (`TestingKey` carries none).
private func namesTestingKey(annotation: TypeSyntax?, initializer: ExprSyntax?) -> Bool {
    if let identifier = annotation?.as(IdentifierTypeSyntax.self), identifier.name.text == "TestingKey" {
        return true
    }
    guard let call = initializer?.as(FunctionCallExprSyntax.self) else { return false }
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
        reference.baseName.text == "TestingKey"
    {
        return true
    }
    return false
}

/// Read one `@BindType(slot, Mock)` attribute into a substitution. The first
/// argument is the slot — a metatype (`Repo.self`) for the type form or a key
/// reference (`Repo.primary`) for the keyed form; the second is the mock's
/// metatype (`MockRepo.self`). Returns `nil` for a malformed attribute the
/// macro's signature would already have rejected.
private func bindTypeSubstitution(
    from attribute: AttributeSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> BindTypeSubstitution? {
    guard case let .argumentList(args) = attribute.arguments, args.count == 2 else { return nil }
    let slotExpression = args.first!.expression
    let mockExpression = args.last!.expression
    guard let mockType = metatypeBase(of: mockExpression) else { return nil }

    let location = makeSourceLocation(of: attribute, sourcePath: sourcePath, converter: converter)
    if let slotType = metatypeBase(of: slotExpression) {
        return BindTypeSubstitution(slotType: slotType, slotKey: nil, mockType: mockType, location: location)
    }
    return BindTypeSubstitution(
        slotType: nil,
        slotKey: slotExpression.trimmedDescription,
        mockType: mockType,
        location: location
    )
}

/// Read one `@Scopable(X.self)` attribute into a marker — the single argument's
/// metatype base names the app-scoped binding the variant permits to lift.
/// Returns `nil` for a malformed attribute the macro's signature would already
/// have rejected.
private func scopableMarker(
    from attribute: AttributeSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> ScopableMarker? {
    guard case let .argumentList(args) = attribute.arguments, args.count == 1,
        let typeName = metatypeBase(of: args.first!.expression)
    else { return nil }
    return ScopableMarker(
        typeName: typeName,
        location: makeSourceLocation(of: attribute, sourcePath: sourcePath, converter: converter)
    )
}

/// The base type of a `.self` metatype expression — `Repo` for `Repo.self`,
/// `Foo<Bar>` for `Foo<Bar>.self` — or `nil` when the expression isn't a
/// metatype. Mirrors `asTypeExpression`, for a positional argument.
private func metatypeBase(of expression: ExprSyntax) -> String? {
    guard let memberAccess = expression.as(MemberAccessExprSyntax.self),
        memberAccess.declName.baseName.text == "self",
        let base = memberAccess.base
    else { return nil }
    return base.trimmedDescription
}
