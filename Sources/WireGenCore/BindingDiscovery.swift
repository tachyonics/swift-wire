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
    /// Every discovered binding partitioned by `(container, scope)`.
    /// `record(_:)` derives the partition from the current visitor
    /// state and the binding's scope identity (currently always nil;
    /// `@Scoped(seed:)` will start populating it). One uniform dict
    /// covers default-graph, container-graph, and any future scope
    /// partitions.
    var allBindings: [Partition: [DiscoveredBinding]] = [:]
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
    /// module-wide `@Container`-name set is known. See `scopes` for
    /// how `VisitorScope.unannotatedExtensionTarget` tracks this.
    var unannotatedExtensionProvides: [UnannotatedExtensionProvides] = []
    /// Module-scope `typealias` declarations. Captured for the
    /// typealias-aware missing-binding hint; nested typealiases
    /// (`enum Names { typealias UserID = UUID }`) and generic
    /// typealiases are deferred.
    var typealiases: [DiscoveredTypealias] = []
    /// Simple names of every primary type declaration (struct, class,
    /// actor, enum, protocol) walked in this file — not extensions.
    /// Drives the cross-module-extension warning: a `@Provides` inside
    /// `extension Foo` where `Foo` isn't in this set across the whole
    /// module is probably extending an imported type.
    var declaredTypeNames: [String] = []
    /// Candidates for the extension-init-conflict warning — `init`s
    /// found inside `extension` blocks that don't carry `@Inject`.
    /// WireGen resolves these against the module-wide
    /// `@Singleton`-name set after aggregation.
    var nonInjectExtensionInits: [NonInjectExtensionInit] = []
    private let sourcePath: String
    private let converter: SourceLocationConverter
    /// One frame per enclosing type the visitor has entered, in
    /// outermost-to-innermost order. `scopes.last` is the immediate
    /// enclosing declaration; an empty stack means module scope.
    /// Bundling the three pieces into one frame keeps push/pop atomic
    /// — there's no way to forget to update one dimension on the way
    /// out.
    private var scopes: [VisitorScope] = []

    private struct VisitorScope {
        /// Type name of this enclosing declaration. Joined with `.`
        /// to produce qualified type names and `@Provides` access
        /// paths.
        let typeName: String
        /// Container the current declaration belongs to (`nil` =
        /// default graph). Set to `typeName` when this scope is
        /// `@Container`-annotated; otherwise inherits from the
        /// parent frame so nested non-container types keep
        /// contributing to whatever container their outer scope
        /// established.
        let containerName: String?
        /// Extended-type name when this scope is an *unannotated*
        /// extension, used to record candidate `@Provides`
        /// declarations for the extension-of-foreign-type warnings.
        /// `nil` for primary type declarations and `@Container`-
        /// annotated extensions.
        let unannotatedExtensionTarget: String?
    }

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

    /// Append a binding to its `(container, scope)` partition. The
    /// container axis comes from the visitor's enclosing-scope stack;
    /// the scope axis comes from the binding's own scope identity
    /// (non-nil for `@Scoped(seed:)`).
    private func record(_ binding: DiscoveredBinding) {
        let scopeKey: ScopeKey? = {
            if case .scopeBound(let scopeBound) = binding { return scopeBound.scopeKey }
            return nil
        }()
        let partition = Partition(
            container: scopes.last?.containerName,
            scope: scopeKey
        )
        allBindings[partition, default: []].append(binding)
    }

    // MARK: Import collection — verbatim text, no semantic analysis.

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(node.trimmedDescription)
        return .skipChildren
    }

    // MARK: Type decls — push/pop the enclosing-type stack and process
    // `@Singleton` if applicable.

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        declaredTypeNames.append(node.name.text)
        warnings.append(
            contentsOf: containerWithScopeWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processScopeBoundType(
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
        declaredTypeNames.append(node.name.text)
        warnings.append(
            contentsOf: containerWithScopeWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processScopeBoundType(
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
        declaredTypeNames.append(node.name.text)
        warnings.append(
            contentsOf: containerWithScopeWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processScopeBoundType(
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
        declaredTypeNames.append(node.name.text)
        warnings.append(
            contentsOf: containerWithScopeWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberWarnings(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        // Protocols can't be @Singleton/@Provides, but their names
        // belong in `declaredTypeNames` so extensions on locally
        // declared protocols don't trip the cross-module warning.
        declaredTypeNames.append(node.name.text)
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Resolve the extended type's simple name. For `extension Foo`
        // and `extension Foo<Bar>`, we want `Foo`. More exotic forms
        // (`extension Foo.Bar`, where-clauses) fall back to the
        // trimmed description.
        let extendedName =
            node.extendedType.as(IdentifierTypeSyntax.self)?.name.text
            ?? node.extendedType.trimmedDescription
        warnings.append(
            contentsOf: injectInitInExtensionWarnings(
                extension: node,
                extendedName: extendedName,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        nonInjectExtensionInits.append(
            contentsOf: nonInjectExtensionInitCandidates(
                extension: node,
                extendedName: extendedName,
                sourcePath: sourcePath,
                converter: converter
            )
        )
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
        if scopes.isEmpty {
            warnings.append(
                contentsOf: strayInjectAtModuleScopeWarnings(
                    for: node,
                    sourcePath: sourcePath,
                    converter: converter
                )
            )
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

    // MARK: Typealiases — only module-scope captured.

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        // Nested typealiases (`enum Names { typealias UserID = UUID }`)
        // and generic typealiases aren't surfaced for the missing-
        // binding hint yet; expand the scope when a real example
        // forces it.
        if scopes.isEmpty, node.genericParameterClause == nil {
            typealiases.append(
                DiscoveredTypealias(
                    name: node.name.text,
                    underlyingType: node.initializer.value.trimmedDescription,
                    location: location(of: node.name)
                )
            )
        }
        return .skipChildren
    }

    // MARK: Helpers

    /// Push one frame onto `scopes` for a type declaration. A
    /// `@Container`-annotated decl opens a new container scope;
    /// anything else inherits the parent's container so nested
    /// non-container types keep contributing to whatever container
    /// their outer scope established.
    private func enterTypeDecl(
        name: String,
        attributes: AttributeListSyntax,
        unannotatedExtensionTarget: String? = nil
    ) {
        let isContainer = hasAttribute(attributes, named: "Container")
        scopes.append(
            VisitorScope(
                typeName: name,
                containerName: isContainer ? name : scopes.last?.containerName,
                unannotatedExtensionTarget: unannotatedExtensionTarget
            )
        )
    }

    private func exitTypeDecl() {
        scopes.removeLast()
    }

    /// `@Provides` is only recognised at module scope or as a `static`
    /// member of an enclosing type. Instance members and locals inside
    /// function bodies are silently skipped.
    private func isAtRecognisedProvidesPosition(modifiers: DeclModifierListSyntax) -> Bool {
        // Top-level — no `static` keyword expected.
        if scopes.isEmpty { return true }
        return modifiers.contains { $0.name.tokenKind == .keyword(.static) }
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
        let accessPath = (scopes.map(\.typeName) + [propertyName]).joined(separator: ".")
        let key = attribute(in: node.attributes, named: "Provides")
            .flatMap { keyIdentifier(from: $0) }
        let providerLocation = location(of: pattern.identifier)
        // Computed properties (`@Provides var x: T { get async throws { … } }`)
        // can carry effect specifiers on the `get` accessor. Stored
        // `@Provides let` bindings can't, so the flags stay `false`
        // for those.
        let propertyEffects = computedPropertyEffectFlags(binding)
        record(
            .provider(
                DiscoveredProvider(
                    boundType: boundType,
                    accessPath: accessPath,
                    form: .property,
                    dependencies: [],
                    genericParameterNames: [],
                    location: providerLocation,
                    keyIdentifier: key,
                    isAsync: propertyEffects.isAsync,
                    isThrowing: propertyEffects.isThrowing
                )
            )
        )
        unannotatedExtensionProvides.append(
            contentsOf: unannotatedExtensionProvidesCandidates(
                providerName: propertyName,
                location: providerLocation,
                extendedType: scopes.last?.unannotatedExtensionTarget
            )
        )
    }

    private func extractProvidesFunction(_ node: FunctionDeclSyntax) {
        guard let returnClause = node.signature.returnClause else {
            // Void-returning `@Provides func` produces nothing
            // injectable. Silently skip.
            return
        }
        let functionName = node.name.text
        let accessPath = (scopes.map(\.typeName) + [functionName]).joined(separator: ".")
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
        unannotatedExtensionProvides.append(
            contentsOf: unannotatedExtensionProvidesCandidates(
                providerName: functionName,
                location: providerLocation,
                extendedType: scopes.last?.unannotatedExtensionTarget
            )
        )
        let effects = functionEffectFlags(node.signature.effectSpecifiers)
        record(
            .provider(
                DiscoveredProvider(
                    boundType: returnClause.type.trimmedDescription,
                    accessPath: accessPath,
                    form: .function,
                    dependencies: dependencies,
                    genericParameterNames: genericParameterNames,
                    location: providerLocation,
                    keyIdentifier: key,
                    isAsync: effects.isAsync,
                    isThrowing: effects.isThrowing
                )
            )
        )
    }

}

extension BindingDiscovery {
    /// Process a primary type declaration for `@Singleton` or
    /// `@Scoped(seed:)` annotations. The two are alternatives — a
    /// type can't sensibly carry both (Swift catches it as a
    /// redeclaration on the synthesised members), so the dispatch
    /// picks at most one. Returns early when neither annotation is
    /// present.
    fileprivate func processScopeBoundType(
        typeKind: String,
        nameToken: TokenSyntax,
        generics: GenericParameterClauseSyntax?,
        attributes: AttributeListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        let scopeKey: ScopeKey?
        if hasAttribute(attributes, named: "Singleton") {
            scopeKey = nil
        } else if let scopedAttribute = attribute(in: attributes, named: "Scoped"),
            let seed = seedTypeExpression(from: scopedAttribute)
        {
            scopeKey = ScopeKey(seed: seed)
        } else {
            return
        }
        let genericParameterNames = generics?.parameters.map { $0.name.text } ?? []
        let injectInfo = extractInjectDependencies(
            from: members,
            sourcePath: sourcePath,
            converter: converter
        )
        // `scopes` already includes this type's own frame (it was
        // pushed by `enterTypeDecl`), so the joined names are the
        // full qualified path.
        let qualified = scopes.map(\.typeName).joined(separator: ".")
        record(
            .scopeBound(
                DiscoveredScopeBoundType(
                    typeName: nameToken.text,
                    qualifiedTypeName: qualified,
                    typeKind: typeKind,
                    genericParameterNames: genericParameterNames,
                    dependencies: injectInfo.dependencies,
                    location: location(of: nameToken),
                    scopeKey: scopeKey,
                    initIsAsync: injectInfo.initIsAsync,
                    initIsThrowing: injectInfo.initIsThrowing,
                    memberInjections: injectInfo.memberInjections
                )
            )
        )
    }
}

// MARK: - File-private helpers

/// Scope-macro attribute names that conflict with `@Container` on
/// the same type. `@Container` routes the type's static members
/// into a separate graph; a scope macro on the same type makes the
/// type a binding in the *default* graph. Combining them means
/// the type is both a node in one graph and a grouping for
/// another — almost always a user error.
private let scopeMacroNames = ["Singleton", "Scoped"]

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

/// Extract the seed type expression from a `@Scoped(seed: SomeType.self)`
/// attribute. Returns the base of the `.self` member access — `"SomeType"`
/// for `SomeType.self`, `"Foo<Bar>"` for `Foo<Bar>.self`. Returns `nil`
/// if the attribute is malformed in a way Swift would catch later
/// (missing argument, non-`.self` expression).
///
/// Generic seed expressions are kept verbatim — `Foo<Bar>` and `Foo<Bar>`
/// are the same scope, `Foo<Baz>` is a different scope. The build
/// plugin's canonical-type-name whitespace normalisation kicks in
/// during graph identity comparisons separately.
private func seedTypeExpression(from attribute: AttributeSyntax) -> String? {
    guard case let .argumentList(args) = attribute.arguments else { return nil }
    guard let seedArg = args.first(where: { $0.label?.text == "seed" }) else { return nil }
    guard let memberAccess = seedArg.expression.as(MemberAccessExprSyntax.self),
        memberAccess.declName.baseName.text == "self",
        let base = memberAccess.base
    else { return nil }
    return base.trimmedDescription
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

private func makeSourceLocation(
    of node: some SyntaxProtocol,
    sourcePath: String,
    converter: SourceLocationConverter
) -> SourceLocation {
    let position = node.startLocation(converter: converter)
    return SourceLocation(file: sourcePath, line: position.line, column: position.column)
}

/// Collect the `@Singleton` type's dependencies. Two output lists:
/// init-time dependencies (returned in `dependencies`) and post-
/// construction member injections (returned in `memberInjections`).
///
/// **Init-time deps.** Same priority rule as `SingletonMacro`: an
/// `@Inject`-marked init's parameter list wins over `@Inject`
/// properties; if neither is present the result is empty. When the
/// init is `@Inject`-marked, its effect specifiers
/// (`async`/`throws`) propagate so emission can prefix the call site
/// with `try`/`await`.
///
/// **Member injections.** Always collected, regardless of which init-
/// time path the type uses:
/// - `@Inject weak var x: T?` becomes a `.propertyAssignment`
///   injection — Wire delivers `T` post-construct via
///   `consumer.x = value`. Swift won't let weak storage live in an
///   init parameter, so this is the only way to express the pattern.
/// - `@Inject func setX(_ x: T) [async] [throws]` becomes a
///   `.methodCall` injection — the user opted into post-construct
///   delivery deliberately (typically to wire deps into custom
///   storage: Mutex-wrapped weak ref, actor message, etc.). The
///   function's effect specifiers carry to the call site.
private func extractInjectDependencies(
    from members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> (
    dependencies: [DependencyParameter],
    initIsAsync: Bool,
    initIsThrowing: Bool,
    memberInjections: [MemberInjection]
) {
    var injectInitDependencies: [DependencyParameter]?
    var initIsAsync = false
    var initIsThrowing = false
    var propertyDependencies: [DependencyParameter] = []
    var memberInjections: [MemberInjection] = []
    for member in members {
        if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
            if hasAttribute(initDecl.attributes, named: "Inject") {
                injectInitDependencies = initDecl.signature.parameterClause.parameters.map {
                    parameter in
                    let parameterKey = attribute(in: parameter.attributes, named: "Inject")
                        .flatMap { keyIdentifier(from: $0) }
                    return DependencyParameter(
                        name: parameterName(parameter),
                        type: parameter.type.trimmedDescription,
                        kind: .injectInitParameter,
                        location: makeSourceLocation(
                            of: parameter.firstName,
                            sourcePath: sourcePath,
                            converter: converter
                        ),
                        keyIdentifier: parameterKey
                    )
                }
                let effects = functionEffectFlags(initDecl.signature.effectSpecifiers)
                initIsAsync = effects.isAsync
                initIsThrowing = effects.isThrowing
            }
            continue
        }
        if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
            hasAttribute(funcDecl.attributes, named: "Inject")
        {
            // `@Inject func setX(_ x: T)` — general post-construct
            // member injection. Each parameter resolves through the
            // graph the same way as init params; codegen emits a
            // method call after the construction sequence.
            let parameters = funcDecl.signature.parameterClause.parameters.map {
                parameter -> DependencyParameter in
                let parameterKey = attribute(in: parameter.attributes, named: "Inject")
                    .flatMap { keyIdentifier(from: $0) }
                return DependencyParameter(
                    name: parameterName(parameter),
                    type: parameter.type.trimmedDescription,
                    kind: .injectMethodParameter,
                    location: makeSourceLocation(
                        of: parameter.firstName,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    keyIdentifier: parameterKey
                )
            }
            let effects = functionEffectFlags(funcDecl.signature.effectSpecifiers)
            memberInjections.append(
                MemberInjection(
                    shape: .methodCall(methodName: funcDecl.name.text),
                    parameters: parameters,
                    isAsync: effects.isAsync,
                    isThrowing: effects.isThrowing,
                    location: makeSourceLocation(
                        of: funcDecl.name,
                        sourcePath: sourcePath,
                        converter: converter
                    )
                )
            )
            continue
        }
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        guard let injectAttribute = attribute(in: varDecl.attributes, named: "Inject")
        else { continue }
        let propertyKey = keyIdentifier(from: injectAttribute)
        // `weak` is a property modifier (e.g. `@Inject weak var x: T?`).
        // Swift requires weak storage to be Optional; Wire strips the
        // `?` for graph identity so the parameter resolves against the
        // producer's `T` binding, not against `T?`. Weak `@Inject`
        // properties become `.propertyAssignment` member injections —
        // the sugar form of method injection.
        let isWeak = varDecl.modifiers.contains { $0.name.text == "weak" }
        for binding in varDecl.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            guard let typeAnnotation = binding.typeAnnotation else { continue }
            let location = makeSourceLocation(
                of: pattern.identifier,
                sourcePath: sourcePath,
                converter: converter
            )
            if isWeak {
                let resolutionType: String
                if let optType = typeAnnotation.type.as(OptionalTypeSyntax.self) {
                    resolutionType = optType.wrappedType.trimmedDescription
                } else {
                    resolutionType = typeAnnotation.type.trimmedDescription
                }
                let parameter = DependencyParameter(
                    name: nil,
                    type: resolutionType,
                    kind: .injectMethodParameter,
                    location: location,
                    keyIdentifier: propertyKey
                )
                memberInjections.append(
                    MemberInjection(
                        shape: .propertyAssignment(propertyName: pattern.identifier.text),
                        parameters: [parameter],
                        location: location
                    )
                )
            } else {
                propertyDependencies.append(
                    DependencyParameter(
                        name: pattern.identifier.text,
                        type: typeAnnotation.type.trimmedDescription,
                        kind: .injectProperty,
                        location: location,
                        keyIdentifier: propertyKey
                    )
                )
            }
        }
    }
    return (
        dependencies: injectInitDependencies ?? propertyDependencies,
        initIsAsync: initIsAsync,
        initIsThrowing: initIsThrowing,
        memberInjections: memberInjections
    )
}

/// `@Container` plus a scope macro on the same type is almost always a
/// user error: `@Container` routes the type's static members into a
/// separate graph, while a scope macro makes the type a binding in the
/// *default* graph — the two roles can't both happen on one type, and
/// neither does what the user probably wants. Warn with a fix-it
/// pointing at the split.
private func containerWithScopeWarnings(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Warning] {
    guard hasAttribute(attributes, named: "Container") else { return [] }
    guard let scope = scopeMacroNames.first(where: { hasAttribute(attributes, named: $0) })
    else { return [] }
    return [
        Warning(
            location: makeSourceLocation(
                of: nameToken,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "'\(nameToken.text)' carries both @Container and @\(scope) — the two roles end up in separate graphs. Split into two declarations: a @\(scope) type for the binding, and a separate @Container type for the grouping."
        )
    ]
}

/// Build a candidate when the `@Provides` was found inside an
/// unannotated extension (i.e. the immediate enclosing scope's
/// `VisitorScope.unannotatedExtensionTarget` is non-nil). WireGen
/// resolves candidates against the module-wide `@Container` name
/// set in a later pass.
private func unannotatedExtensionProvidesCandidates(
    providerName: String,
    location: SourceLocation,
    extendedType: String?
) -> [UnannotatedExtensionProvides] {
    guard let extendedType else { return [] }
    return [
        UnannotatedExtensionProvides(
            extendedType: extendedType,
            providerName: providerName,
            location: location
        )
    ]
}

/// `@Inject` on the members of a non-scope-annotated type is a silent
/// no-op — there's no macro on the enclosing type to read it. Emit a
/// warning per `@Inject`-marked init or stored property so the user
/// understands they need a scope macro to get wiring.
private func strayInjectMemberWarnings(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Warning] {
    // If the type itself carries a scope macro, `@Inject` on its
    // members IS meaningful — the scope macro reads them. Skip.
    if scopeMacroNames.contains(where: { hasAttribute(attributes, named: $0) }) {
        return []
    }
    var warnings: [Warning] = []
    for member in members {
        if let initDecl = member.decl.as(InitializerDeclSyntax.self),
            let injectAttr = attribute(in: initDecl.attributes, named: "Inject")
        {
            warnings.append(
                Warning(
                    location: makeSourceLocation(
                        of: injectAttr,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    message:
                        "@Inject on this initialiser has no effect — '\(nameToken.text)' has no scope macro. Add a scope macro to the type (@Singleton, @RequestScope, or @JobScope) to enable wiring."
                )
            )
            continue
        }
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
            let injectAttr = attribute(in: varDecl.attributes, named: "Inject")
        else { continue }
        for binding in varDecl.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            warnings.append(
                Warning(
                    location: makeSourceLocation(
                        of: injectAttr,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    message:
                        "@Inject on '\(pattern.identifier.text)' has no effect — '\(nameToken.text)' has no scope macro. Add a scope macro to the type (@Singleton, @RequestScope, or @JobScope) to enable wiring."
                )
            )
        }
    }
    return warnings
}

/// `@Inject let foo = ...` at module scope is a silent no-op — there's
/// no enclosing type for any macro to read it from. Most often the
/// user meant `@Provides`.
private func strayInjectAtModuleScopeWarnings(
    for node: VariableDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Warning] {
    guard let injectAttr = attribute(in: node.attributes, named: "Inject") else { return [] }
    guard let binding = node.bindings.first,
        let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else { return [] }
    return [
        Warning(
            location: makeSourceLocation(
                of: injectAttr,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "@Inject on '\(pattern.identifier.text)' at module scope has no effect — use @Provides for module-scope bindings."
        )
    ]
}

/// `@Inject` on an init declared in an extension is ignored by the
/// `@Singleton` macro — peer macros only see the primary declaration's
/// members. Warn so the user knows to move the init back to the
/// primary type.
private func injectInitInExtensionWarnings(
    extension extensionNode: ExtensionDeclSyntax,
    extendedName: String,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Warning] {
    var warnings: [Warning] = []
    for member in extensionNode.memberBlock.members {
        guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
        guard let injectAttr = attribute(in: initDecl.attributes, named: "Inject") else {
            continue
        }
        warnings.append(
            Warning(
                location: makeSourceLocation(
                    of: injectAttr,
                    sourcePath: sourcePath,
                    converter: converter
                ),
                message:
                    "@Inject on an extension init has no effect — move the init into the primary declaration of '\(extendedName)' so the @Singleton macro can see it."
            )
        )
    }
    return warnings
}

/// Record every non-`@Inject` `init` inside an extension as a
/// candidate. WireGen filters these against the module-wide
/// `@Singleton`-name set after aggregation — the warning fires only
/// when the extended type is a `@Singleton`, since that's when the
/// macro-generated init enters the picture.
private func nonInjectExtensionInitCandidates(
    extension extensionNode: ExtensionDeclSyntax,
    extendedName: String,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [NonInjectExtensionInit] {
    var candidates: [NonInjectExtensionInit] = []
    for member in extensionNode.memberBlock.members {
        guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
        if hasAttribute(initDecl.attributes, named: "Inject") { continue }
        candidates.append(
            NonInjectExtensionInit(
                extendedType: extendedName,
                location: makeSourceLocation(
                    of: initDecl.initKeyword,
                    sourcePath: sourcePath,
                    converter: converter
                )
            )
        )
    }
    return candidates
}
