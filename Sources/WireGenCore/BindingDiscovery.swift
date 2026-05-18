import SwiftSyntax

/// Walks a parsed source tree looking for `@Singleton`-annotated types
/// and `@Provides`-annotated declarations. For each, captures the data
/// the graph and code emission need: bound type, dependencies, source
/// location, and (for providers) the access path under the consumer's
/// module.
///
/// Dependency source preference for `@Singleton` matches
/// `SingletonMacro`'s rule:
/// 1. If the type has an `@Inject`-marked initialiser, dependencies
///    come from that initialiser's parameter list.
/// 2. Otherwise, dependencies come from `@Inject`-marked stored
///    properties in declaration order.
///
/// `@Provides` recognised positions:
/// - Module-scope `let`/`var` and `func` declarations
/// - `static let`/`static var` and `static func` members of any
///   enclosing type (struct, class, enum, actor)
///
/// Other positions (instance members, locals inside functions) are
/// silently ignored. The macro itself is a marker — the validation
/// happens in the build plugin's discovery (which simply doesn't see
/// them) and in the consumer's compiler errors if they `@Inject` a
/// dependency no binding satisfies.
final class BindingDiscovery: SyntaxVisitor {
    /// Default-graph bindings: module-scope `@Provides`, module-scope
    /// `@Singleton`s, and static `@Provides` on non-`@Container`
    /// enclosing types.
    var bindings: [DiscoveredBinding] = []
    /// Bindings discovered inside `@Container` enums, keyed by
    /// container name. The same `DiscoveredBinding` model is reused —
    /// the container partition is purely about *where* a binding goes.
    var containerBindings: [String: [DiscoveredBinding]] = [:]
    /// Verbatim `import` statements found in the source — captured for
    /// propagation into the generated `_WireGraph.swift` so any types
    /// referenced by discovered bindings stay in scope. Includes
    /// `@_implementationOnly`, `@testable`, and other modifiers since
    /// `trimmedDescription` preserves them.
    var imports: [String] = []
    /// Source-pattern warnings the visitor accumulates as it walks the
    /// tree (e.g. `@Container` combined with a scope annotation, or
    /// `@Inject` on an extension init that the macro can't see).
    var warnings: [Warning] = []
    /// `@Provides` sites discovered inside unannotated extensions —
    /// the build plugin resolves these into warnings after the
    /// module-wide `@Container`-name set is known. See
    /// `unannotatedExtensionStack` for the scope tracking.
    var unannotatedExtensionProvides: [UnannotatedExtensionProvides] = []
    private let sourcePath: String
    private let converter: SourceLocationConverter
    /// Stack of enclosing type names — top of stack is the immediate
    /// enclosing type. Used to compute `accessPath` for static
    /// `@Provides` members of nested types.
    private var enclosingTypes: [String] = []
    /// Parallel stack of extended-type names for each enclosing
    /// declaration that is an *unannotated* extension. Pushed
    /// alongside `enclosingTypes`/`containerScope` on every type-
    /// decl entry and popped on exit, so the depth stays in sync.
    /// Non-extension type decls push `nil`. The top of the stack is
    /// the extended-type of the immediately enclosing unannotated
    /// extension, or `nil` when the immediate parent is anything
    /// else.
    private var unannotatedExtensionStack: [String?] = [nil]
    /// Stack of "active container" names, pushed/popped alongside
    /// enclosing type entries. Top of stack is the container the
    /// current declaration belongs to (`nil` = default graph). When
    /// entering a `@Container`-annotated declaration (primary enum or
    /// `@Container extension Foo`) the contributing type's name is
    /// pushed; non-container declarations push the current top to
    /// preserve scope through nested type declarations.
    private var containerScope: [String?] = [nil]

    init(sourcePath: String, converter: SourceLocationConverter) {
        self.sourcePath = sourcePath
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// Resolve the 1-based file/line/col of a syntax node's start
    /// position. Used by everything that needs a `SourceLocation`.
    private func location(of node: some SyntaxProtocol) -> SourceLocation {
        let position = node.startLocation(converter: converter)
        return SourceLocation(
            file: sourcePath,
            line: position.line,
            column: position.column
        )
    }

    /// Append a binding to either the default graph or the active
    /// container's bucket. The top of `containerScope` is the
    /// container name when inside a `@Container` scope, or `nil` for
    /// the default graph.
    private func record(_ binding: DiscoveredBinding) {
        if let container = containerScope.last ?? nil {
            containerBindings[container, default: []].append(binding)
        } else {
            bindings.append(binding)
        }
    }

    // MARK: Import collection — verbatim text, no semantic analysis.

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(node.trimmedDescription)
        return .skipChildren
    }

    // MARK: Type decls — push/pop the enclosing-type stack and process
    // `@Singleton` if applicable.

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        emitContainerWithScopeWarningIfNeeded(
            nameToken: node.name,
            attributes: node.attributes
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processSingleton(
            typeKind: "struct",
            nameToken: node.name,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        emitContainerWithScopeWarningIfNeeded(
            nameToken: node.name,
            attributes: node.attributes
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processSingleton(
            typeKind: "class",
            nameToken: node.name,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        emitContainerWithScopeWarningIfNeeded(
            nameToken: node.name,
            attributes: node.attributes
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processSingleton(
            typeKind: "actor",
            nameToken: node.name,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        // Enums can't be `@Singleton` (no stored properties to inject)
        // but can host `@Provides static` members — the canonical
        // caseless-enum-as-namespace pattern. They can also be
        // `@Container`-annotated, in which case bindings inside the
        // primary declaration are routed to that container.
        emitContainerWithScopeWarningIfNeeded(
            nameToken: node.name,
            attributes: node.attributes
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Resolve the extended type's simple name. For `extension Foo`
        // and `extension Foo<Bar>`, we want `Foo`. More exotic forms
        // (`extension Foo.Bar`, where-clauses) fall back to the
        // trimmed description.
        let extendedName: String
        if let identifier = node.extendedType.as(IdentifierTypeSyntax.self) {
            extendedName = identifier.name.text
        } else {
            extendedName = node.extendedType.trimmedDescription
        }
        emitInjectInitInExtensionWarningIfNeeded(extension: node, extendedName: extendedName)
        // `@Container extension Foo { ... }` opts the extension into
        // Foo's container, merging with any other declarations
        // (primary type or other `@Container` extensions) that target
        // the same type name. Plain extensions inherit the surrounding
        // container scope, so bindings inside fall through to the
        // default graph at top level. Iteration 3's diagnostic gallery
        // will warn when an unannotated extension's bindings probably
        // weren't meant to leak into the default graph.
        let isAnnotatedAsContainer = hasAttribute(node.attributes, named: "Container")
        enterTypeDecl(
            name: extendedName,
            attributes: node.attributes,
            unannotatedExtensionTarget: isAnnotatedAsContainer ? nil : extendedName
        )
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        exitTypeDecl()
    }

    // MARK: `@Provides` on variables and functions.

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasAttribute(node.attributes, named: "Provides"),
            isAtRecognisedProvidesPosition(modifiers: node.modifiers)
        {
            extractProvidesProperty(node)
        }
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasAttribute(node.attributes, named: "Provides"),
            isAtRecognisedProvidesPosition(modifiers: node.modifiers)
        {
            extractProvidesFunction(node)
        }
        return .skipChildren
    }

    // MARK: Helpers

    /// Push the matching scope for a type declaration: the type's name
    /// onto `enclosingTypes`, and either the type's own name (when the
    /// declaration is `@Container`-annotated, opening a new container
    /// scope) or the inherited current container (when it isn't, so
    /// nested non-container types keep contributing to whatever
    /// container their outer scope established). The push is symmetric
    /// with `exitTypeDecl()` regardless of whether the type was
    /// `@Container`-annotated, so the visitor's `visit`/`visitPost`
    /// pairs always balance without external bookkeeping.
    private func enterTypeDecl(
        name: String,
        attributes: AttributeListSyntax,
        unannotatedExtensionTarget: String? = nil
    ) {
        enclosingTypes.append(name)
        if hasAttribute(attributes, named: "Container") {
            containerScope.append(name)
        } else {
            containerScope.append(containerScope.last ?? nil)
        }
        unannotatedExtensionStack.append(unannotatedExtensionTarget)
    }

    private func exitTypeDecl() {
        unannotatedExtensionStack.removeLast()
        containerScope.removeLast()
        enclosingTypes.removeLast()
    }

    /// `@Provides` is only recognised at module scope or as a `static`
    /// member of an enclosing type. Instance members and locals inside
    /// function bodies are silently skipped.
    private func isAtRecognisedProvidesPosition(modifiers: DeclModifierListSyntax) -> Bool {
        if enclosingTypes.isEmpty {
            // Top-level — no `static` keyword expected.
            return true
        }
        return modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.static)
        }
    }

    private func processSingleton(
        typeKind: String,
        nameToken: TokenSyntax,
        generics: GenericParameterClauseSyntax?,
        attributes: AttributeListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        guard hasAttribute(attributes, named: "Singleton") else { return }
        let genericParameterNames = generics?.parameters.map { $0.name.text } ?? []
        let dependencies = extractInjectDependencies(from: members)
        // `enclosingTypes` already includes this type's own name (it
        // was pushed by `enterTypeDecl` before `processSingleton` ran),
        // so it's the full path including the singleton itself.
        let qualified = enclosingTypes.joined(separator: ".")
        record(
            .singleton(
                DiscoveredSingleton(
                    typeName: nameToken.text,
                    qualifiedTypeName: qualified,
                    typeKind: typeKind,
                    genericParameterNames: genericParameterNames,
                    dependencies: dependencies,
                    location: location(of: nameToken)
                )
            )
        )
    }

    private func extractProvidesProperty(_ node: VariableDeclSyntax) {
        // Multi-binding declarations (`let a = 1, b = 2`) are skipped:
        // they're a rare style and supporting them complicates the
        // `accessPath` story for no real-world gain.
        guard node.bindings.count == 1, let binding = node.bindings.first else { return }
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return }

        // The bound type is taken from one of two places, in order:
        //   1. An explicit type annotation: `let x: Foo = ...`
        //   2. A `Foo(...)` constructor-call initialiser, when the
        //      annotation is omitted: `let x = Foo()`.
        // Both are idiomatic Swift; preferring annotation when present
        // keeps the user's intent honest (they can write a wider type
        // than the RHS produces, e.g. `let x: any Logger = AppLogger()`).
        let boundType: String
        if let typeAnnotation = binding.typeAnnotation {
            boundType = typeAnnotation.type.trimmedDescription
        } else if let inferred = inferTypeFromConstructorCall(binding.initializer?.value) {
            boundType = inferred
        } else {
            // Can't determine the bound type without running type
            // inference. Skip silently — same posture as `@Inject`
            // properties without annotations.
            return
        }

        let propertyName = pattern.identifier.text
        let accessPath = (enclosingTypes + [propertyName]).joined(separator: ".")
        let key = attribute(in: node.attributes, named: "Provides")
            .flatMap { keyIdentifier(from: $0) }
        let providerLocation = location(of: pattern.identifier)
        record(
            .provider(
                DiscoveredProvider(
                    boundType: boundType,
                    accessPath: accessPath,
                    form: .property,
                    dependencies: [],
                    genericParameterNames: [],
                    location: providerLocation,
                    keyIdentifier: key
                )
            )
        )
        recordUnannotatedExtensionProvidesIfNeeded(
            providerName: propertyName,
            location: providerLocation
        )
    }

    private func extractProvidesFunction(_ node: FunctionDeclSyntax) {
        guard let returnClause = node.signature.returnClause else {
            // Void-returning `@Provides func` produces nothing
            // injectable. Silently skip.
            return
        }
        let functionName = node.name.text
        let accessPath = (enclosingTypes + [functionName]).joined(separator: ".")
        let dependencies = node.signature.parameterClause.parameters.map { parameter in
            // Per-parameter `@Inject(<key>)` lets a consumer name the
            // keyed binding it wants. A bare parameter (no attribute)
            // is an unkeyed dep — same as if the user wrote `@Inject`
            // with no argument, which is also legal but redundant here
            // since `@Provides func` parameters are implicitly deps.
            let parameterKey = attribute(in: parameter.attributes, named: "Inject")
                .flatMap { keyIdentifier(from: $0) }
            return DependencyParameter(
                name: parameterName(parameter),
                type: parameter.type.trimmedDescription,
                kind: .providerFunctionParameter,
                location: location(of: parameter.firstName),
                keyIdentifier: parameterKey
            )
        }
        let genericParameterNames =
            node.genericParameterClause?.parameters.map { $0.name.text } ?? []
        let key = attribute(in: node.attributes, named: "Provides")
            .flatMap { keyIdentifier(from: $0) }
        let providerLocation = location(of: node.name)
        recordUnannotatedExtensionProvidesIfNeeded(
            providerName: functionName,
            location: providerLocation
        )
        record(
            .provider(
                DiscoveredProvider(
                    boundType: returnClause.type.trimmedDescription,
                    accessPath: accessPath,
                    form: .function,
                    dependencies: dependencies,
                    genericParameterNames: genericParameterNames,
                    location: providerLocation,
                    keyIdentifier: key
                )
            )
        )
    }

    private func extractInjectDependencies(
        from members: MemberBlockItemListSyntax
    ) -> [DependencyParameter] {
        // Single pass: collect both candidate dependency lists. Choose
        // at the end based on the same priority rule as
        // `SingletonMacro`: an `@Inject`-marked init's parameter list
        // takes precedence over `@Inject` properties.
        var injectInitDependencies: [DependencyParameter]?
        var propertyDependencies: [DependencyParameter] = []

        for member in members {
            if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
                if hasAttribute(initDecl.attributes, named: "Inject") {
                    injectInitDependencies = initDecl.signature.parameterClause.parameters.map {
                        parameter in
                        // Per-parameter `@Inject(<key>)` keys an
                        // individual dep. The init-level `@Inject` (no
                        // args) marks the init as canonical; its key —
                        // if any — applies to nothing.
                        let parameterKey = attribute(in: parameter.attributes, named: "Inject")
                            .flatMap { keyIdentifier(from: $0) }
                        return DependencyParameter(
                            name: parameterName(parameter),
                            type: parameter.type.trimmedDescription,
                            kind: .injectInitParameter,
                            location: location(of: parameter.firstName),
                            keyIdentifier: parameterKey
                        )
                    }
                }
                continue
            }

            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let injectAttribute = attribute(in: varDecl.attributes, named: "Inject")
            else { continue }
            let propertyKey = keyIdentifier(from: injectAttribute)
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                guard let typeAnnotation = binding.typeAnnotation else { continue }
                propertyDependencies.append(
                    DependencyParameter(
                        name: pattern.identifier.text,
                        type: typeAnnotation.type.trimmedDescription,
                        kind: .injectProperty,
                        location: location(of: pattern.identifier),
                        keyIdentifier: propertyKey
                    )
                )
            }
        }

        return injectInitDependencies ?? propertyDependencies
    }

    private func emitContainerWithScopeWarningIfNeeded(
        nameToken: TokenSyntax,
        attributes: AttributeListSyntax
    ) {
        guard hasAttribute(attributes, named: "Container") else { return }
        guard
            let scope = scopeMacroNames.first(where: {
                hasAttribute(attributes, named: $0)
            })
        else { return }
        warnings.append(
            Warning(
                location: location(of: nameToken),
                message:
                    "'\(nameToken.text)' carries both @Container and @\(scope); the two roles end up in separate graphs. Split into two declarations: a @\(scope) type for the binding, and a separate @Container type for the grouping."
            )
        )
    }

    /// When the current parse position is directly inside an
    /// unannotated extension, record a candidate site for the
    /// `@Provides`-in-unannotated-extension warning. The build plugin
    /// resolves these into real warnings after the module-wide
    /// `@Container`-name set is known — without that cross-file view
    /// the visitor can't tell whether the warning should fire.
    private func recordUnannotatedExtensionProvidesIfNeeded(
        providerName: String,
        location: SourceLocation
    ) {
        guard let extendedType = unannotatedExtensionStack.last ?? nil else { return }
        unannotatedExtensionProvides.append(
            UnannotatedExtensionProvides(
                extendedType: extendedType,
                providerName: providerName,
                location: location
            )
        )
    }

    /// Surface `@Inject` on an extension init. The `@Singleton` macro
    /// only sees the primary declaration's members, so an `@Inject`
    /// init in an extension is silently dropped — Wire never picks it
    /// up as the canonical initialiser. The remedy is moving the init
    /// into the primary declaration. The warning points at the init
    /// site itself so the user lands on the offending code.
    private func emitInjectInitInExtensionWarningIfNeeded(
        extension extensionNode: ExtensionDeclSyntax,
        extendedName: String
    ) {
        for member in extensionNode.memberBlock.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
            guard hasAttribute(initDecl.attributes, named: "Inject") else { continue }
            warnings.append(
                Warning(
                    location: location(of: initDecl.initKeyword),
                    message:
                        "@Inject on an extension init is ignored — the @Singleton macro only sees the primary declaration. Move this init into the primary declaration of '\(extendedName)' if it's meant to be Wire's canonical initialiser."
                )
            )
        }
    }
}

// MARK: - File-private helpers

/// Scope-macro attribute names that conflict with `@Container` on
/// the same type. `@Container` routes the type's static members
/// into a separate graph; a scope macro on the same type makes the
/// type a binding in the *default* graph. Combining them means
/// the type is both a node in one graph and a grouping for
/// another — almost always a user error.
private let scopeMacroNames = ["Singleton", "RequestScope", "JobScope"]

/// Find the first attribute in the list matching `name`, or `nil`.
/// Used to reach the attribute's argument list when extracting a
/// key identifier from `@Inject(...)` / `@Provides(...)`.
private func attribute(
    in attributes: AttributeListSyntax,
    named name: String
) -> AttributeSyntax? {
    for element in attributes {
        guard let attribute = element.as(AttributeSyntax.self) else { continue }
        if attribute.attributeName.trimmedDescription == name {
            return attribute
        }
    }
    return nil
}

private func hasAttribute(
    _ attributes: AttributeListSyntax,
    named name: String
) -> Bool {
    attribute(in: attributes, named: name) != nil
}

/// Extract the canonical key identifier from an attribute's argument
/// list. Returns `nil` for the unkeyed form (no parentheses or empty
/// argument list). For the keyed form `@Inject(<expr>)` returns the
/// trimmed text of `<expr>` — `Database.primary` → "Database.primary".
///
/// The build plugin matches keyed bindings to keyed consumers by
/// canonical text, so what the user writes IS the key. `Foo.primary`
/// on one side matches `Foo.primary` on the other; `.primary` does
/// not match `Foo.primary` (different canonical text), and Swift's
/// type inference for leading-dot is a separate concern handled by
/// the macro signature, not the build plugin.
private func keyIdentifier(from attribute: AttributeSyntax) -> String? {
    guard case let .argumentList(args) = attribute.arguments else { return nil }
    guard let firstArg = args.first else { return nil }
    return firstArg.expression.trimmedDescription
}

/// The parameter's external label — what callers write at the call
/// site. The generated bootstrap emits `Type(label: resolvedValue)`
/// calls and needs the label.
///
/// Returns `nil` for wildcard (`_`) labels so the call site is told
/// to omit the label entirely rather than emit `"_"` as a sentinel
/// the consumer has to special-case downstream.
///
/// - `init(label internal: A)` → `"label"`
/// - `init(_ a: A)` → `nil`
/// - `init(a: A)` → `"a"`
///
/// The internal name (`secondName`, when present) is irrelevant — it
/// only appears inside the init body, which is the user's code, not
/// Wire's.
private func parameterName(_ parameter: FunctionParameterSyntax) -> String? {
    if parameter.firstName.tokenKind == .wildcard {
        return nil
    }
    return parameter.firstName.text
}

/// Recover the bound type from a `Foo(...)` or `Foo<Bar>(...)`
/// initializer when the user omitted the type annotation. Returns
/// `nil` for any other expression shape — member access
/// (`Foo.shared`), function calls returning unspecified types
/// (`makeFoo()`), literals, etc. — so the caller falls back to
/// skipping the declaration. The first-character-uppercase check
/// filters out lowercase function calls that would otherwise be
/// misidentified as type references.
private func inferTypeFromConstructorCall(_ expr: ExprSyntax?) -> String? {
    guard let call = expr?.as(FunctionCallExprSyntax.self) else { return nil }
    let called = call.calledExpression
    // Plain `Foo` or generic-specialised `Foo<Bar>`. Member access
    // (`Foo.shared` or `Module.Foo`) is rejected — for a plain
    // type-construction call the called expression is a single
    // identifier or a generic specialization of one.
    guard
        called.is(DeclReferenceExprSyntax.self)
            || called.is(GenericSpecializationExprSyntax.self)
    else { return nil }
    let text = called.trimmedDescription
    guard let first = text.first, first.isUppercase else { return nil }
    return text
}
