import SwiftParser
import SwiftSyntax

// MARK: - Discovery model

/// One `@Singleton`-annotated type found in a source file, with the
/// dependency declaration extracted from either an `@Inject`-marked init
/// or from `@Inject` stored properties on the type.
public struct DiscoveredSingleton: Sendable {
    public let typeName: String
    public let typeKind: String
    public let genericParameterNames: [String]
    public let dependencies: [DependencyParameter]
    public let sourcePath: String

    public init(
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
public struct DependencyParameter: Sendable {
    public let name: String
    public let type: String
    public let kind: DependencyKind

    public init(name: String, type: String, kind: DependencyKind) {
        self.name = name
        self.type = type
        self.kind = kind
    }
}

public enum DependencyKind: Sendable, Equatable {
    case injectProperty
    case injectInitParameter
}

// MARK: - Top-level entry points

/// Parse one source file and return every `@Singleton`-annotated type it
/// contains, with dependencies extracted via the same priority rule as
/// `SingletonMacro` (an `@Inject`-marked init's parameter list takes
/// precedence over `@Inject` stored properties).
public func discoverSingletons(
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
public func renderDiscoveryReport(
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
                    lines.append("    \(dep.name): \(dep.type)   (\(kindLabel))")
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

    /// The parameter's "internal" name — the one used inside the function
    /// body. For `init(_ a: Int)` that's `a` (secondName). For
    /// `init(label internal: Int)` that's `internal`. For `init(a: Int)`
    /// it's `a` (firstName, since secondName is nil).
    private func parameterName(_ parameter: FunctionParameterSyntax) -> String {
        if parameter.firstName.tokenKind == .wildcard {
            return parameter.secondName?.text ?? "_"
        }
        return parameter.secondName?.text ?? parameter.firstName.text
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
