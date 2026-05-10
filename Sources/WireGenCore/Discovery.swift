import SwiftParser
import SwiftSyntax

// MARK: - Discovery model

/// One binding the build plugin found in source — either a `@Singleton`
/// type whose construction Wire owns, or a `@Provides`-declared property
/// or function the user wrote to supply a value.
///
/// The graph algorithm operates uniformly on `DiscoveredBinding` via the
/// accessors below. The kind only matters at code emission, where the
/// construction call shape differs (`Type(args)` vs `accessPath` vs
/// `accessPath(args)`).
package enum DiscoveredBinding: Sendable {
    case singleton(DiscoveredSingleton)
    case provider(DiscoveredProvider)
}

extension DiscoveredBinding {
    /// The type the binding produces. For `@Singleton` this is the
    /// type's name; for `@Provides` it's the property's annotated type
    /// or the function's return type. Bindings are graph-keyed by this.
    package var boundType: String {
        switch self {
        case .singleton(let singleton): return singleton.typeName
        case .provider(let provider): return provider.boundType
        }
    }

    /// The bound type as referenced from the generated `_WireGraph.swift`
    /// at module scope — qualified with any enclosing type prefix for
    /// `@Singleton`s nested inside another type (typically a
    /// `@Container`). `@Provides` bindings use their declared type
    /// expression as-is; if a user writes a `@Provides` returning a
    /// nested type, they need to qualify the type annotation
    /// themselves (limitation we'll surface as a diagnostic in
    /// iteration 3 if it bites).
    package var boundTypeReference: String {
        switch self {
        case .singleton(let singleton): return singleton.qualifiedTypeName
        case .provider(let provider): return provider.boundType
        }
    }

    /// Dependencies the binding needs at construction — `@Inject`
    /// parameters/properties for `@Singleton`, function parameters for
    /// `@Provides func`, empty for `@Provides let`.
    package var dependencies: [DependencyParameter] {
        switch self {
        case .singleton(let singleton): return singleton.dependencies
        case .provider(let provider): return provider.dependencies
        }
    }

    /// Generic-parameter names declared on the binding. The graph uses
    /// these to skip bindings that can't be resolved without a concrete
    /// specialisation pass (not yet implemented).
    package var genericParameterNames: [String] {
        switch self {
        case .singleton(let singleton): return singleton.genericParameterNames
        case .provider(let provider): return provider.genericParameterNames
        }
    }

    package var sourcePath: String {
        switch self {
        case .singleton(let singleton): return singleton.sourcePath
        case .provider(let provider): return provider.sourcePath
        }
    }
}

/// One `@Singleton`-annotated type found in a source file, with the
/// dependency declaration extracted from either an `@Inject`-marked init
/// or from `@Inject` stored properties on the type.
///
/// `typeName` is the simple type name (`MockService`); the graph keys
/// bindings by this. `qualifiedTypeName` is the same name prefixed by
/// any enclosing types' names (`TestContainer.MockService` for a
/// `@Singleton` nested inside a `@Container` enum, or just
/// `MockService` for a top-level `@Singleton`). Code emission uses
/// `qualifiedTypeName` at the construction site since the generated
/// `_wireBootstrap...` function lives at module scope and can't see
/// nested types unqualified.
package struct DiscoveredSingleton: Sendable {
    package let typeName: String
    package let qualifiedTypeName: String
    package let typeKind: String
    package let genericParameterNames: [String]
    package let dependencies: [DependencyParameter]
    package let sourcePath: String

    package init(
        typeName: String,
        qualifiedTypeName: String? = nil,
        typeKind: String,
        genericParameterNames: [String],
        dependencies: [DependencyParameter],
        sourcePath: String
    ) {
        self.typeName = typeName
        // Default to the simple name so existing call sites that pass
        // only `typeName` (top-level singletons in tests, etc.) keep
        // working without explicit qualification.
        self.qualifiedTypeName = qualifiedTypeName ?? typeName
        self.typeKind = typeKind
        self.genericParameterNames = genericParameterNames
        self.dependencies = dependencies
        self.sourcePath = sourcePath
    }
}

/// One `@Provides`-declared binding — either a property (no
/// dependencies) or a function whose parameters become its
/// dependencies. Lives at module scope or as a `static` member of any
/// non-`@Container` enclosing type (struct, class, enum, actor).
///
/// The `accessPath` is what the generated bootstrap writes after the
/// module qualifier — `logger` for a top-level `let logger`, or
/// `Config.dbURL` for a `static let dbURL` on `enum Config`. Nested
/// enclosing types are joined with `.` (e.g., `Outer.Inner.foo`).
package struct DiscoveredProvider: Sendable {
    package let boundType: String
    package let accessPath: String
    package let form: Form
    package let dependencies: [DependencyParameter]
    package let genericParameterNames: [String]
    package let sourcePath: String

    package init(
        boundType: String,
        accessPath: String,
        form: Form,
        dependencies: [DependencyParameter],
        genericParameterNames: [String],
        sourcePath: String
    ) {
        self.boundType = boundType
        self.accessPath = accessPath
        self.form = form
        self.dependencies = dependencies
        self.genericParameterNames = genericParameterNames
        self.sourcePath = sourcePath
    }

    /// Whether the binding source is a property (read its value directly)
    /// or a function (call it with resolved arguments).
    package enum Form: Sendable, Equatable {
        case property
        case function
    }
}

/// One dependency that the synthesised (or user-marked) initialiser takes
/// — i.e. one parameter Wire must resolve from the graph at construction
/// time.
///
/// `name` is the external argument label used at the call site. `nil`
/// represents a wildcard label (the `_` form, e.g. `init(_ a: A)`),
/// where the call site omits the label entirely. Property-based
/// injection always produces a concrete label (the property name);
/// only `@Inject init(_ x: Foo)` produces a `nil` name.
package struct DependencyParameter: Sendable {
    package let name: String?
    package let type: String
    package let kind: DependencyKind

    package init(name: String?, type: String, kind: DependencyKind) {
        self.name = name
        self.type = type
        self.kind = kind
    }
}

package enum DependencyKind: Sendable, Equatable {
    case injectProperty
    case injectInitParameter
    case providerFunctionParameter
}

// MARK: - Top-level entry points

/// Bindings and imports discovered in a single source file. Both
/// products of one parse — the visitor walks the tree once and
/// captures `@Singleton`/`@Provides` declarations alongside `import`
/// statements, partitioning bindings between the default graph and
/// any `@Container` enums encountered.
package struct SourceFileDiscovery: Sendable {
    /// Bindings that feed the default graph: module-scope `@Provides`,
    /// module-scope `@Singleton`s, and static `@Provides` on
    /// enclosing types that are *not* `@Container`-annotated.
    package let bindings: [DiscoveredBinding]
    /// Bindings inside `@Container`-annotated declarations, keyed by
    /// container name. Each container's list contains `@Provides`
    /// static members and nested `@Singleton` types from every
    /// `@Container`-annotated declaration that targets the same type
    /// name (a primary `@Container enum Foo` plus any
    /// `@Container extension Foo` declarations all contribute here).
    /// Plain (un-`@Container`-annotated) extensions don't contribute;
    /// their bindings fall through to the default `bindings` list.
    package let containerBindings: [String: [DiscoveredBinding]]
    package let imports: [String]

    package init(
        bindings: [DiscoveredBinding],
        containerBindings: [String: [DiscoveredBinding]] = [:],
        imports: [String]
    ) {
        self.bindings = bindings
        self.containerBindings = containerBindings
        self.imports = imports
    }
}

/// Parse one source file and return every `@Singleton` and `@Provides`
/// binding it contains, plus every `import` declaration. Singletons
/// follow the same priority rule as `SingletonMacro` for dependencies
/// (an `@Inject`-marked init's parameter list takes precedence over
/// `@Inject` stored properties). Providers come from module-scope
/// `let`/`func` declarations and from `static let`/`static func`
/// members of enclosing types. Imports are captured verbatim,
/// preserving access modifiers (`@testable`, `@_implementationOnly`,
/// etc.) so the build plugin can propagate them into the generated
/// `_WireGraph.swift`.
package func discover(
    in source: String,
    sourcePath: String
) -> SourceFileDiscovery {
    let syntaxTree = Parser.parse(source: source)
    let visitor = BindingDiscovery(sourcePath: sourcePath)
    visitor.walk(syntaxTree)
    return SourceFileDiscovery(
        bindings: visitor.bindings,
        containerBindings: visitor.containerBindings,
        imports: visitor.imports
    )
}

/// Render a human-readable summary of bindings discovered grouped by
/// source file. Files with no discoveries are omitted to keep the
/// report scannable.
package func renderDiscoveryReport(
    perFile: [(path: String, items: [DiscoveredBinding])]
) -> String {
    var lines: [String] = []
    lines.append("WireGen discovery report")
    lines.append("")

    var totalCount = 0
    let sourceFileCount = perFile.count

    for (path, items) in perFile {
        guard !items.isEmpty else { continue }
        lines.append("\(path):")
        for item in items {
            totalCount += 1
            switch item {
            case .singleton(let singleton):
                renderSingleton(singleton, into: &lines)
            case .provider(let provider):
                renderProvider(provider, into: &lines)
            }
        }
        lines.append("")
    }

    lines.append(
        "discovered \(totalCount) binding(s) across \(sourceFileCount) source file(s)"
    )

    return lines.joined(separator: "\n")
}

private func renderSingleton(_ item: DiscoveredSingleton, into lines: inout [String]) {
    let generics =
        item.genericParameterNames.isEmpty
        ? ""
        : "<\(item.genericParameterNames.joined(separator: ", "))>"
    lines.append("  @Singleton \(item.typeKind) \(item.typeName)\(generics)")
    if item.dependencies.isEmpty {
        lines.append("    (no dependencies)")
    } else {
        for dep in item.dependencies {
            lines.append("    \(dependencyLine(dep))")
        }
    }
}

private func renderProvider(_ item: DiscoveredProvider, into lines: inout [String]) {
    let generics =
        item.genericParameterNames.isEmpty
        ? ""
        : "<\(item.genericParameterNames.joined(separator: ", "))>"
    let formLabel: String
    switch item.form {
    case .property: formLabel = "let"
    case .function: formLabel = "func"
    }
    lines.append(
        "  @Provides \(formLabel) \(item.accessPath)\(generics) -> \(item.boundType)"
    )
    if item.dependencies.isEmpty {
        lines.append("    (no dependencies)")
    } else {
        for dep in item.dependencies {
            lines.append("    \(dependencyLine(dep))")
        }
    }
}

private func dependencyLine(_ dep: DependencyParameter) -> String {
    let kindLabel: String
    switch dep.kind {
    case .injectProperty: kindLabel = "@Inject property"
    case .injectInitParameter: kindLabel = "@Inject init parameter"
    case .providerFunctionParameter: kindLabel = "@Provides function parameter"
    }
    // Wildcard-label parameters render as `_` to match the source-level
    // form. The sentinel only appears in human-facing output here;
    // codegen receives the actual `nil` from `DependencyParameter.name`.
    let displayName = dep.name ?? "_"
    return "\(displayName): \(dep.type)   (\(kindLabel))"
}

// MARK: - Discovery visitor

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
    private let sourcePath: String
    /// Stack of enclosing type names — top of stack is the immediate
    /// enclosing type. Used to compute `accessPath` for static
    /// `@Provides` members of nested types.
    private var enclosingTypes: [String] = []
    /// Stack of "active container" names, pushed/popped alongside
    /// enclosing type entries. Top of stack is the container the
    /// current declaration belongs to (`nil` = default graph). When
    /// entering a `@Container`-annotated declaration (primary enum or
    /// `@Container extension Foo`) the contributing type's name is
    /// pushed; non-container declarations push the current top to
    /// preserve scope through nested type declarations.
    private var containerScope: [String?] = [nil]

    init(sourcePath: String) {
        self.sourcePath = sourcePath
        super.init(viewMode: .sourceAccurate)
    }

    /// The container this declaration belongs to, or `nil` for the
    /// default graph.
    private var currentContainer: String? {
        containerScope.last ?? nil
    }

    /// Append a binding to either the default graph or the active
    /// container's bucket, based on the current container scope.
    private func record(_ binding: DiscoveredBinding) {
        if let container = currentContainer {
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
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processSingleton(
            typeKind: "struct",
            name: node.name.text,
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
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processSingleton(
            typeKind: "class",
            name: node.name.text,
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
        enterTypeDecl(name: node.name.text, attributes: node.attributes)
        processSingleton(
            typeKind: "actor",
            name: node.name.text,
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
        // `@Container extension Foo { ... }` opts the extension into
        // Foo's container, merging with any other declarations
        // (primary type or other `@Container` extensions) that target
        // the same type name. Plain extensions inherit the surrounding
        // container scope, so bindings inside fall through to the
        // default graph at top level. Iteration 3's diagnostic gallery
        // will warn when an unannotated extension's bindings probably
        // weren't meant to leak into the default graph.
        enterTypeDecl(name: extendedName, attributes: node.attributes)
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
    private func enterTypeDecl(name: String, attributes: AttributeListSyntax) {
        enclosingTypes.append(name)
        if hasAttribute(attributes, named: "Container") {
            containerScope.append(name)
        } else {
            containerScope.append(currentContainer)
        }
    }

    private func exitTypeDecl() {
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
        name: String,
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
                    typeName: name,
                    qualifiedTypeName: qualified,
                    typeKind: typeKind,
                    genericParameterNames: genericParameterNames,
                    dependencies: dependencies,
                    sourcePath: sourcePath
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
        record(
            .provider(
                DiscoveredProvider(
                    boundType: boundType,
                    accessPath: accessPath,
                    form: .property,
                    dependencies: [],
                    genericParameterNames: [],
                    sourcePath: sourcePath
                )
            )
        )
    }

    /// Recover the bound type from a `Foo(...)` or `Foo<Bar>(...)`
    /// initializer when the user omitted the type annotation. Returns
    /// `nil` for any other expression shape — member access (`Foo.shared`),
    /// function calls returning unspecified types (`makeFoo()`),
    /// literals, etc. — so the caller falls back to skipping the
    /// declaration. The first-character-uppercase check filters out
    /// lowercase function calls that would otherwise be misidentified
    /// as type references.
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

    private func extractProvidesFunction(_ node: FunctionDeclSyntax) {
        guard let returnClause = node.signature.returnClause else {
            // Void-returning `@Provides func` produces nothing
            // injectable. Silently skip.
            return
        }
        let functionName = node.name.text
        let accessPath = (enclosingTypes + [functionName]).joined(separator: ".")
        let dependencies = node.signature.parameterClause.parameters.map { parameter in
            DependencyParameter(
                name: parameterName(parameter),
                type: parameter.type.trimmedDescription,
                kind: .providerFunctionParameter
            )
        }
        let genericParameterNames =
            node.genericParameterClause?.parameters.map { $0.name.text } ?? []
        record(
            .provider(
                DiscoveredProvider(
                    boundType: returnClause.type.trimmedDescription,
                    accessPath: accessPath,
                    form: .function,
                    dependencies: dependencies,
                    genericParameterNames: genericParameterNames,
                    sourcePath: sourcePath
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
                        DependencyParameter(
                            name: parameterName(parameter),
                            type: parameter.type.trimmedDescription,
                            kind: .injectInitParameter
                        )
                    }
                }
                continue
            }

            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard hasAttribute(varDecl.attributes, named: "Inject") else { continue }
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                guard let typeAnnotation = binding.typeAnnotation else { continue }
                propertyDependencies.append(
                    DependencyParameter(
                        name: pattern.identifier.text,
                        type: typeAnnotation.type.trimmedDescription,
                        kind: .injectProperty
                    )
                )
            }
        }

        return injectInitDependencies ?? propertyDependencies
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

    private func hasAttribute(
        _ attributes: AttributeListSyntax,
        named name: String
    ) -> Bool {
        attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            return attribute.attributeName.trimmedDescription == name
        }
    }
}
