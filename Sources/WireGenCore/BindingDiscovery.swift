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

/// One enclosing-type frame on `BindingDiscovery.scopes`.
private struct VisitorScope {
    /// Type name of this enclosing declaration. Joined with `.` to
    /// produce qualified type names and `@Provides` access paths.
    let typeName: String
    /// Container the current declaration belongs to (`nil` = default
    /// graph). Set to `typeName` when this scope is `@Container`-
    /// annotated; otherwise inherits from the parent frame so nested
    /// non-container types keep contributing to whatever container
    /// their outer scope established.
    let containerName: String?
    /// Source-level access of this enclosing declaration, folded into
    /// the effective access of every binding nested inside (so a
    /// `@Provides` in a `private enum` is flagged unreachable even when
    /// its own modifier is `internal`). See `effectiveAccess`.
    let access: AccessLevel
    /// Extended-type name when this scope is an *unannotated*
    /// extension, used to record candidate `@Provides` declarations for
    /// the extension-of-foreign-type warnings. `nil` for primary type
    /// declarations and `@Container`-annotated extensions.
    let unannotatedExtensionTarget: String?
    /// Seed scope the enclosing `@Scoped(seed:)` namespace enum defines
    /// for its `@Provides` (the scope-axis sibling of `@Container`); `nil`
    /// outside any scope block, and inherited by nested frames.
    /// Self-producing `@Scoped` *types* carry their own scope, not this.
    let seedScope: ScopeKey?
}

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
    var warnings: [Diagnostic] = []
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
    /// Multibinding key declarations (`CollectedKey`/`MappedKey`/
    /// `BuilderKey` `static let`s) found in this file, in source order.
    /// The aggregate's element/value/result type is read producer-side
    /// from these.
    var multibindingKeys: [DiscoveredMultibindingKey] = []
    /// Single-binding key declarations (`BindingKey<T>` `static let`s)
    /// found in this file. Aggregated across the module by `WireGen` and
    /// matched against `@Inject(K)` / `@Provides(K)` references (unified
    /// with `multibindingKeys`) to diagnose references to undeclared keys.
    var bindingKeys: [DiscoveredBindingKey] = []
    /// Adapter-annotation definitions (`WireAdapterAnnotationV1` declarations)
    /// found in this file. Aggregated across the module by `WireGen` and
    /// matched by name against adapter use-sites to resolve and validate the
    /// generated `_wireRegister` calls.
    var adapterAnnotations: [DiscoveredAdapterAnnotation] = []
    /// `@resultBuilder` types found in this file, with their fold result
    /// type — the producer-side result type a `BuilderKey` aggregate has.
    var resultBuilders: [DiscoveredResultBuilder] = []
    private let sourcePath: String
    private let converter: SourceLocationConverter
    /// The module these sources belong to, stamped onto every discovered
    /// binding and key at construction. The build passes the consumer
    /// target name; tests pass a stand-in.
    private let module: String
    /// One frame per enclosing type the visitor has entered, in
    /// outermost-to-innermost order. `scopes.last` is the immediate
    /// enclosing declaration; an empty stack means module scope.
    /// Bundling each frame's dimensions into one value keeps push/pop
    /// atomic — there's no way to forget to update one on the way out.
    private var scopes: [VisitorScope] = []

    init(sourcePath: String, converter: SourceLocationConverter, module: String) {
        self.sourcePath = sourcePath
        self.converter = converter
        self.module = module
        super.init(viewMode: .sourceAccurate)
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
        recordResultBuilder(
            name: node.name,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        warnings.append(
            contentsOf: containerWithScopeDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes, modifiers: node.modifiers)
        processScopeBoundType(
            typeKind: "struct",
            nameToken: node.name,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            members: node.memberBlock.members
        )
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        declaredTypeNames.append(node.name.text)
        recordResultBuilder(
            name: node.name,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        warnings.append(
            contentsOf: containerWithScopeDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes, modifiers: node.modifiers)
        processScopeBoundType(
            typeKind: "class",
            nameToken: node.name,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
            members: node.memberBlock.members
        )
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) {
        exitTypeDecl()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        declaredTypeNames.append(node.name.text)
        recordResultBuilder(
            name: node.name,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        warnings.append(
            contentsOf: containerWithScopeDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(name: node.name.text, attributes: node.attributes, modifiers: node.modifiers)
        processScopeBoundType(
            typeKind: "actor",
            nameToken: node.name,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            modifiers: node.modifiers,
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
        recordResultBuilder(
            name: node.name,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        warnings.append(
            contentsOf: containerWithScopeDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        warnings.append(
            contentsOf: strayInjectMemberDiagnostics(
                nameToken: node.name,
                attributes: node.attributes,
                members: node.memberBlock.members,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        enterTypeDecl(
            name: node.name.text,
            attributes: node.attributes,
            modifiers: node.modifiers,
            seedScopeBlock: scopeBlockKey(in: node.attributes)
        )
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
        recordResultBuilder(
            name: node.name,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
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
            contentsOf: injectInitInExtensionDiagnostics(
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
            modifiers: node.modifiers,
            unannotatedExtensionTarget: isAnnotatedAsContainer ? nil : extendedName
        )
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        exitTypeDecl()
    }

    // MARK: `@Provides` on variables and functions.

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if isAtRecognisedProvidesPosition(modifiers: node.modifiers),
            let key = multibindingKey(
                from: node,
                enclosingTypeNames: scopes.map(\.typeName),
                enclosingAccessLevels: scopes.map(\.access),
                sourcePath: sourcePath,
                converter: converter,
                module: module
            )
        {
            multibindingKeys.append(key)
        }
        if isAtRecognisedProvidesPosition(modifiers: node.modifiers),
            let key = bindingKey(
                from: node,
                enclosingTypeNames: scopes.map(\.typeName),
                enclosingAccessLevels: scopes.map(\.access),
                sourcePath: sourcePath,
                converter: converter,
                module: module
            )
        {
            bindingKeys.append(key)
        }
        if isAtRecognisedProvidesPosition(modifiers: node.modifiers),
            let definition = adapterAnnotation(
                from: node,
                sourcePath: sourcePath,
                converter: converter,
                module: module
            )
        {
            adapterAnnotations.append(definition)
        }
        if hasAttribute(node.attributes, named: "Provides"),
            isAtRecognisedProvidesPosition(modifiers: node.modifiers)
        {
            extractProvidesProperty(node)
        }
        if scopes.isEmpty {
            warnings.append(
                contentsOf: strayInjectAtModuleScopeDiagnostics(
                    for: node,
                    sourcePath: sourcePath,
                    converter: converter
                )
            )
        }
        warnings.append(contentsOf: producerlessMarkerDiagnostics(in: node.attributes))
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasAttribute(node.attributes, named: "Provides"),
            isAtRecognisedProvidesPosition(modifiers: node.modifiers)
        {
            extractProvidesFunction(node)
        }
        warnings.append(contentsOf: producerlessMarkerDiagnostics(in: node.attributes))
        return .skipChildren
    }

    /// `@Contributes` on a var/func with no co-located `@Provides`
    /// producer — the contribution would be silently dropped. Returns
    /// empty unless `@Contributes` is present, so it's safe on every
    /// declaration. (`@Scoped` on a var/func is now a compiler error —
    /// the macro is member-only — so it needs no plugin check.)
    private func producerlessMarkerDiagnostics(in attributes: AttributeListSyntax) -> [Diagnostic] {
        strayContributesDiagnostics(
            in: attributes,
            producerMacros: ["Provides"],
            sourcePath: sourcePath,
            converter: converter
        )
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
        modifiers: DeclModifierListSyntax,
        unannotatedExtensionTarget: String? = nil,
        seedScopeBlock: ScopeKey? = nil
    ) {
        // `@Contributes` on a type/extension requires a `@Singleton`/
        // `@Scoped` producer; flag the bare form before it's silently
        // dropped. Covers every type kind and extensions in one place.
        warnings.append(
            contentsOf: strayContributesDiagnostics(
                in: attributes,
                producerMacros: ["Singleton", "Scoped"],
                sourcePath: sourcePath,
                converter: converter
            )
        )
        let isContainer = hasAttribute(attributes, named: "Container")
        scopes.append(
            VisitorScope(
                typeName: name,
                containerName: isContainer ? name : scopes.last?.containerName,
                access: accessLevel(from: modifiers),
                unannotatedExtensionTarget: unannotatedExtensionTarget,
                seedScope: seedScopeBlock ?? scopes.last?.seedScope
            )
        )
    }

    private func exitTypeDecl() {
        scopes.removeLast()
    }

    /// Capture a `@resultBuilder` type's fold result type. A no-op for
    /// declarations that aren't result builders (including protocols).
    private func recordResultBuilder(
        name: TokenSyntax,
        attributes: AttributeListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        if let builder = resultBuilder(
            named: name,
            attributes: attributes,
            members: members,
            sourcePath: sourcePath,
            converter: converter
        ) {
            resultBuilders.append(builder)
        }
    }

    /// `@Provides` is only recognised at module scope or as a `static`
    /// member of an enclosing type. Instance members and locals inside
    /// function bodies are silently skipped.
    private func isAtRecognisedProvidesPosition(modifiers: DeclModifierListSyntax) -> Bool {
        // Top-level — no `static` keyword expected.
        if scopes.isEmpty { return true }
        return modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }

}

extension BindingDiscovery {
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
    /// container axis comes from the visitor's enclosing-scope stack; the
    /// scope axis comes from the binding's own scope identity (non-nil for
    /// `@Scoped(seed:)`). Bindings are already stamped with the discovery
    /// module at construction.
    private func record(_ binding: DiscoveredBinding) {
        let scopeKey: ScopeKey? =
            switch binding {
            case .scopeBound(let scopeBound): scopeBound.scopeKey
            case .provider(let provider): provider.scopeKey
            case .aggregate: nil
            }
        let partition = Partition(
            container: scopes.last?.containerName,
            scope: scopeKey
        )
        allBindings[partition, default: []].append(binding)
    }

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
        modifiers: DeclModifierListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        let scopeKey: ScopeKey?
        let allowUnused: Bool
        if let singletonAttribute = attribute(in: attributes, named: "Singleton") {
            scopeKey = nil
            allowUnused = allowUnusedFlag(from: singletonAttribute)
        } else if let scopedAttribute = attribute(in: attributes, named: "Scoped"),
            let seed = seedTypeExpression(from: scopedAttribute)
        {
            scopeKey = ScopeKey(seed: seed)
            allowUnused = allowUnusedFlag(from: scopedAttribute)
        } else {
            return
        }
        warnings.append(
            contentsOf: singletonInScopeBlockDiagnostics(
                typeName: nameToken.text,
                ownScope: scopeKey,
                blockSeed: scopes.last?.seedScope,
                location: location(of: nameToken)
            )
        )
        warnings.append(
            contentsOf: scopeBoundTypeTeardownMisuse(
                in: attributes,
                sourcePath: sourcePath,
                converter: converter
            )
        )
        let genericParameterNames = generics?.parameters.map { $0.name.text } ?? []
        let injectResult = extractInjectDependencies(
            from: members,
            hostTypeKind: typeKind,
            sourcePath: sourcePath,
            converter: converter
        )
        warnings.append(contentsOf: injectResult.diagnostics)
        // `dropLast` drops this type's own frame (pushed by
        // `enterTypeDecl`) — only *enclosing* scopes cap its access.
        if let diagnostic = declarationTooPrivateDiagnostic(
            surfaceLabel: scopeKey == nil ? "@Singleton type" : "@Scoped type",
            name: nameToken.text,
            ownAccess: accessLevel(from: modifiers),
            enclosing: scopes.dropLast().map { ($0.typeName, $0.access) },
            location: location(of: nameToken)
        ) {
            warnings.append(diagnostic)
        }
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
                    dependencies: injectResult.dependencies,
                    location: location(of: nameToken),
                    scopeKey: scopeKey,
                    initIsAsync: injectResult.initIsAsync,
                    initIsThrowing: injectResult.initIsThrowing,
                    memberInjections: injectResult.memberInjections,
                    accessLevel: accessLevel(from: modifiers),
                    contributions: contributions(
                        in: attributes,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    allowUnused: allowUnused,
                    teardown: injectResult.teardown,
                    originModule: module
                )
            )
        )
    }

    fileprivate func extractProvidesProperty(_ node: VariableDeclSyntax) {
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
        let providesAttribute = attribute(in: node.attributes, named: "Provides")
        let key = providesAttribute.flatMap { keyIdentifier(from: $0) }
        let scopeKey = scopes.last?.seedScope
        let providerLocation = location(of: pattern.identifier)
        // Computed properties (`@Provides var x: T { get async throws { … } }`)
        // can carry effect specifiers on the `get` accessor. Stored
        // `@Provides let` bindings can't, so the flags stay `false`
        // for those.
        let propertyEffects = computedPropertyEffectFlags(binding)
        let providerAccess = accessLevel(from: node.modifiers)
        if let diagnostic = declarationTooPrivateDiagnostic(
            surfaceLabel: "@Provides declaration",
            name: propertyName,
            ownAccess: providerAccess,
            enclosing: scopes.map { ($0.typeName, $0.access) },
            location: providerLocation
        ) {
            warnings.append(diagnostic)
        }
        let teardown = providerTeardownAction(
            in: node.attributes,
            sourcePath: sourcePath,
            converter: converter
        )
        warnings.append(contentsOf: teardown.diagnostics)
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
                    isThrowing: propertyEffects.isThrowing,
                    accessLevel: providerAccess,
                    scopeKey: scopeKey,
                    contributions: contributions(
                        in: node.attributes,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    allowUnused: providesAttribute.map { allowUnusedFlag(from: $0) } ?? false,
                    teardown: teardown.action,
                    originModule: module
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

    fileprivate func extractProvidesFunction(_ node: FunctionDeclSyntax) {
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
        let providesAttribute = attribute(in: node.attributes, named: "Provides")
        let key = providesAttribute.flatMap { keyIdentifier(from: $0) }
        let scopeKey = scopes.last?.seedScope
        let providerLocation = location(of: node.name)
        unannotatedExtensionProvides.append(
            contentsOf: unannotatedExtensionProvidesCandidates(
                providerName: functionName,
                location: providerLocation,
                extendedType: scopes.last?.unannotatedExtensionTarget
            )
        )
        let effects = functionEffectFlags(node.signature.effectSpecifiers)
        let providerAccess = accessLevel(from: node.modifiers)
        if let diagnostic = declarationTooPrivateDiagnostic(
            surfaceLabel: "@Provides function",
            name: functionName,
            ownAccess: providerAccess,
            enclosing: scopes.map { ($0.typeName, $0.access) },
            location: providerLocation
        ) {
            warnings.append(diagnostic)
        }
        let teardown = providerTeardownAction(
            in: node.attributes,
            sourcePath: sourcePath,
            converter: converter
        )
        warnings.append(contentsOf: teardown.diagnostics)
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
                    isThrowing: effects.isThrowing,
                    accessLevel: providerAccess,
                    scopeKey: scopeKey,
                    contributions: contributions(
                        in: node.attributes,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    allowUnused: providesAttribute.map { allowUnusedFlag(from: $0) } ?? false,
                    teardown: teardown.action,
                    originModule: module
                )
            )
        )
    }

    /// Seed a `@Scoped(seed:)` namespace enum defines for its `@Provides`
    /// — `nil` when there's no `@Scoped` or its seed can't be read.
    fileprivate func scopeBlockKey(in attributes: AttributeListSyntax) -> ScopeKey? {
        attribute(in: attributes, named: "Scoped")
            .flatMap { seedTypeExpression(from: $0) }
            .map { ScopeKey(seed: $0) }
    }
}

// MARK: - File-private helpers

/// Scope-macro attribute names that conflict with `@Container` on
/// the same type. `@Container` routes the type's static members
/// into a separate graph; a scope macro on the same type makes the
/// type a binding in the *default* graph. Combining them means
/// the type is both a node in one graph and a grouping for
/// another — almost always a user error.
let scopeMacroNames = ["Singleton", "Scoped"]

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
private func strayInjectMemberDiagnostics(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    // If the type itself carries a scope macro, `@Inject` on its
    // members IS meaningful — the scope macro reads them. Skip.
    if scopeMacroNames.contains(where: { hasAttribute(attributes, named: $0) }) {
        return []
    }
    var warnings: [Diagnostic] = []
    for member in members {
        if let initDecl = member.decl.as(InitializerDeclSyntax.self),
            let injectAttr = attribute(in: initDecl.attributes, named: "Inject")
        {
            warnings.append(
                Diagnostic(
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
                Diagnostic(
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
private func strayInjectAtModuleScopeDiagnostics(
    for node: VariableDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard let injectAttr = attribute(in: node.attributes, named: "Inject") else { return [] }
    guard let binding = node.bindings.first,
        let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else { return [] }
    return [
        Diagnostic(
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
private func injectInitInExtensionDiagnostics(
    extension extensionNode: ExtensionDeclSyntax,
    extendedName: String,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    var warnings: [Diagnostic] = []
    for member in extensionNode.memberBlock.members {
        guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
        guard let injectAttr = attribute(in: initDecl.attributes, named: "Inject") else {
            continue
        }
        warnings.append(
            Diagnostic(
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
