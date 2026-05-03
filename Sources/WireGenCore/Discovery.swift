import SwiftParser
import SwiftSyntax

// MARK: - Discovery model

/// One `@Singleton`-annotated type found in a source file, with the
/// dependency declaration extracted from either an `@Inject`-marked init
/// or from `@Inject` stored properties on the type.
package struct DiscoveredSingleton: Sendable {
    package let typeName: String
    package let typeKind: String
    package let genericParameterNames: [String]
    package let dependencies: [DependencyParameter]
    package let sourcePath: String

    package init(
        typeName: String,
        typeKind: String,
        genericParameterNames: [String],
        dependencies: [DependencyParameter],
        sourcePath: String
    ) {
        self.typeName = typeName
        self.typeKind = typeKind
        self.genericParameterNames = genericParameterNames
        self.dependencies = dependencies
        self.sourcePath = sourcePath
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
}

// MARK: - Top-level entry points

/// Parse one source file and return every `@Singleton`-annotated type it
/// contains, with dependencies extracted via the same priority rule as
/// `SingletonMacro` (an `@Inject`-marked init's parameter list takes
/// precedence over `@Inject` stored properties).
package func discoverSingletons(
    in source: String,
    sourcePath: String
) -> [DiscoveredSingleton] {
    let syntaxTree = Parser.parse(source: source)
    let visitor = SingletonDiscovery(sourcePath: sourcePath)
    visitor.walk(syntaxTree)
    return visitor.discovered
}

/// Render a human-readable summary of `@Singleton` discoveries grouped
/// by source file. Files with no discoveries are omitted to keep the
/// report scannable.
package func renderDiscoveryReport(
    perFile: [(path: String, items: [DiscoveredSingleton])]
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
            let generics =
                item.genericParameterNames.isEmpty
                ? ""
                : "<\(item.genericParameterNames.joined(separator: ", "))>"
            lines.append("  @Singleton \(item.typeKind) \(item.typeName)\(generics)")
            if item.dependencies.isEmpty {
                lines.append("    (no dependencies)")
            } else {
                for dep in item.dependencies {
                    let kindLabel: String
                    switch dep.kind {
                    case .injectProperty: kindLabel = "@Inject property"
                    case .injectInitParameter: kindLabel = "@Inject init parameter"
                    }
                    // For wildcard-label parameters, render as `_` since
                    // that's the Swift source-level representation. The
                    // sentinel character only appears in human-facing
                    // output here; codegen receives the actual `nil`.
                    let displayName = dep.name ?? "_"
                    lines.append("    \(displayName): \(dep.type)   (\(kindLabel))")
                }
            }
        }
        lines.append("")
    }

    lines.append(
        "discovered \(totalCount) @Singleton type(s) across \(sourceFileCount) source file(s)"
    )

    return lines.joined(separator: "\n")
}

// MARK: - Discovery visitor

/// Walks a parsed source tree looking for `@Singleton`-annotated types.
/// For each, captures the type's name, generic parameter list, and
/// dependencies in declaration-order.
///
/// Dependency source preference matches `SingletonMacro`'s rule:
/// 1. If the type has an `@Inject`-marked initialiser, dependencies come
///    from that initialiser's parameter list.
/// 2. Otherwise, dependencies come from `@Inject`-marked stored
///    properties in declaration order.
///
/// Validation (multiple `@Inject` inits, mixing init+property `@Inject`,
/// etc.) is the macro's job and fires during the consumer's compilation.
/// WireGen is downstream of that and assumes the inputs are well-formed
/// enough to discover; mismatches surface at construction-time codegen
/// in sittings 3–4.
final class SingletonDiscovery: SyntaxVisitor {
    var discovered: [DiscoveredSingleton] = []
    private let sourcePath: String

    init(sourcePath: String) {
        self.sourcePath = sourcePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        process(
            typeKind: "struct",
            name: node.name.text,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        process(
            typeKind: "class",
            name: node.name.text,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        process(
            typeKind: "actor",
            name: node.name.text,
            generics: node.genericParameterClause,
            attributes: node.attributes,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    private func process(
        typeKind: String,
        name: String,
        generics: GenericParameterClauseSyntax?,
        attributes: AttributeListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        guard hasAttribute(attributes, named: "Singleton") else { return }
        let genericParameterNames = generics?.parameters.map { $0.name.text } ?? []
        let dependencies = extractDependencies(from: members)
        discovered.append(
            DiscoveredSingleton(
                typeName: name,
                typeKind: typeKind,
                genericParameterNames: genericParameterNames,
                dependencies: dependencies,
                sourcePath: sourcePath
            )
        )
    }

    private func extractDependencies(
        from members: MemberBlockItemListSyntax
    ) -> [DependencyParameter] {
        // Single pass: collect both candidate dependency lists. Choose at
        // the end based on the same priority rule as `SingletonMacro`:
        // an `@Inject`-marked init's parameter list takes precedence over
        // `@Inject` properties.
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
    /// site. Sitting 4's bootstrap emits `Type(label: resolvedValue)`
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
