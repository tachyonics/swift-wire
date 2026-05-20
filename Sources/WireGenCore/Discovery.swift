import SwiftParser
import SwiftSyntax

// MARK: - Source positions

/// A position in a source file — file path plus 1-based line and column.
/// Carried by every discovered binding and dependency so diagnostics can
/// emit `file:line:col: error: ...` output that Swift toolchains
/// (Xcode, the swiftc-driven build pipeline) surface as clickable
/// errors. Discovery populates these from `SwiftSyntax`'s
/// `SourceLocationConverter`; tests construct them directly.
package struct SourceLocation: Sendable, Hashable {
    package let file: String
    package let line: Int
    package let column: Int

    package init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    /// `file:line:col` — the prefix Swift compiler diagnostics use, so
    /// downstream tools recognise the position and link it back to the
    /// source.
    package var formattedPrefix: String {
        "\(file):\(line):\(column)"
    }
}

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

    package var location: SourceLocation {
        switch self {
        case .singleton(let singleton): return singleton.location
        case .provider(let provider): return provider.location
        }
    }

    package var sourcePath: String {
        location.file
    }

    /// The binding's key identifier, or `nil` for unkeyed bindings.
    /// `@Singleton`s are always unkeyed; only `@Provides` can be keyed.
    /// Graph identity is `(boundType, keyIdentifier?)`.
    package var keyIdentifier: String? {
        switch self {
        case .singleton: return nil
        case .provider(let provider): return provider.keyIdentifier
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
    /// Position of the type-name identifier in source — what the user
    /// would navigate to from a diagnostic.
    package let location: SourceLocation

    package var sourcePath: String { location.file }

    package init(
        typeName: String,
        qualifiedTypeName: String? = nil,
        typeKind: String,
        genericParameterNames: [String],
        dependencies: [DependencyParameter],
        location: SourceLocation
    ) {
        self.typeName = typeName
        // Default to the simple name so existing call sites that pass
        // only `typeName` (top-level singletons in tests, etc.) keep
        // working without explicit qualification.
        self.qualifiedTypeName = qualifiedTypeName ?? typeName
        self.typeKind = typeKind
        self.genericParameterNames = genericParameterNames
        self.dependencies = dependencies
        self.location = location
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
    /// Position of the property/function identifier — what the user
    /// would navigate to from a diagnostic.
    package let location: SourceLocation
    /// Canonical text of the `@Provides(<expr>)` argument, or `nil` for
    /// the unkeyed form. Two bindings of the same type with different
    /// `keyIdentifier`s coexist in the graph; same type with same key
    /// is a duplicate.
    package let keyIdentifier: String?
    /// Concrete type arguments to splice into the call site when this
    /// provider was produced by specialising a generic provider
    /// function — e.g. `["DynamoDBTable"]` for a specialised
    /// `func makeRepo<T>() -> Repository<T>` invoked as
    /// `makeRepo<DynamoDBTable>()`. Empty for non-specialised
    /// providers (concrete property and function bindings); only the
    /// generic-specialisation phase populates this.
    package let concreteGenericArguments: [String]

    package var sourcePath: String { location.file }

    package init(
        boundType: String,
        accessPath: String,
        form: Form,
        dependencies: [DependencyParameter],
        genericParameterNames: [String],
        location: SourceLocation,
        keyIdentifier: String? = nil,
        concreteGenericArguments: [String] = []
    ) {
        self.boundType = boundType
        self.accessPath = accessPath
        self.form = form
        self.dependencies = dependencies
        self.genericParameterNames = genericParameterNames
        self.location = location
        self.keyIdentifier = keyIdentifier
        self.concreteGenericArguments = concreteGenericArguments
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
    /// Position of the parameter or property identifier in source — the
    /// `@Inject` site (or `@Provides func` parameter) the diagnostic
    /// should point at when this dependency can't be resolved.
    package let location: SourceLocation
    /// Canonical text of the `@Inject(<expr>)` argument when the
    /// consumer is selecting a keyed binding, or `nil` for the unkeyed
    /// form. Unkeyed deps match only unkeyed bindings; keyed deps
    /// match only same-key bindings (Dagger-style — keys partition the
    /// binding space).
    package let keyIdentifier: String?

    package init(
        name: String?,
        type: String,
        kind: DependencyKind,
        location: SourceLocation,
        keyIdentifier: String? = nil
    ) {
        self.name = name
        self.type = type
        self.kind = kind
        self.location = location
        self.keyIdentifier = keyIdentifier
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
    /// Source-pattern warnings the visitor surfaced during this file's
    /// parse — things like `@Inject` on an extension init (silently
    /// ignored by the macro) or `@Container` combined with a scope
    /// annotation. Informational; WireGen renders them but does not
    /// fail the build on warnings alone.
    package let warnings: [Warning]
    /// `@Provides` sites found inside *unannotated* extensions
    /// (`extension Foo { @Provides ... }` where the extension itself
    /// is not `@Container`-annotated). Needs aggregation across all
    /// files to resolve into a warning — the warning fires when the
    /// extended type has a `@Container` declaration *somewhere*, and
    /// only `WireGen` knows the module-wide container-name set.
    package let unannotatedExtensionProvides: [UnannotatedExtensionProvides]
    /// Module-scope `typealias` declarations captured per-file and
    /// aggregated across the module. Drives the typealias hint that
    /// missing-binding diagnostics use to point at the underlying type
    /// when a typealias was injected but its underlying type IS bound.
    package let typealiases: [DiscoveredTypealias]
    /// Simple names of every primary type declaration (struct, class,
    /// actor, enum, protocol) found in this file. Aggregated across the
    /// module by `WireGen` to drive the cross-module-extension warning
    /// — an unannotated `extension Foo` whose `Foo` isn't in this set
    /// is probably extending an imported type.
    package let declaredTypeNames: [String]

    package init(
        bindings: [DiscoveredBinding],
        containerBindings: [String: [DiscoveredBinding]] = [:],
        imports: [String],
        warnings: [Warning] = [],
        unannotatedExtensionProvides: [UnannotatedExtensionProvides] = [],
        typealiases: [DiscoveredTypealias] = [],
        declaredTypeNames: [String] = []
    ) {
        self.bindings = bindings
        self.containerBindings = containerBindings
        self.imports = imports
        self.warnings = warnings
        self.unannotatedExtensionProvides = unannotatedExtensionProvides
        self.typealiases = typealiases
        self.declaredTypeNames = declaredTypeNames
    }
}

/// One module-scope `typealias` declaration captured during discovery.
/// Used at validation time to enrich missing-binding diagnostics: if
/// `@Inject var x: UserID` fails to resolve but `UserID` is a typealias
/// of a type that IS bound, a `note:` line points at the underlying
/// type so the user understands why the lookup didn't match. Typealiases
/// are not unwrapped during resolution — `typealias UserID = UUID`
/// followed by separate keyed bindings for each is a legitimate
/// discriminator pattern.
package struct DiscoveredTypealias: Sendable {
    /// The typealias's own name, as written (e.g. `"UserID"`).
    package let name: String
    /// The right-hand-side type expression, trimmed (e.g. `"UUID"`).
    package let underlyingType: String
    package let location: SourceLocation

    package init(name: String, underlyingType: String, location: SourceLocation) {
        self.name = name
        self.underlyingType = underlyingType
        self.location = location
    }
}

/// One `@Provides` site found inside an unannotated extension.
/// Carried through discovery as a candidate; the build plugin
/// resolves it into a `Warning` after the module-wide
/// `@Container`-name set is available.
package struct UnannotatedExtensionProvides: Sendable {
    /// The extension's extended type name — what the warning checks
    /// against the container set.
    package let extendedType: String
    /// Display name of the offending `@Provides` declaration, for
    /// the warning message (e.g. property/function source name).
    package let providerName: String
    /// Anchor for the warning's `file:line:col:` prefix.
    package let location: SourceLocation

    package init(extendedType: String, providerName: String, location: SourceLocation) {
        self.extendedType = extendedType
        self.providerName = providerName
        self.location = location
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
    let converter = SourceLocationConverter(fileName: sourcePath, tree: syntaxTree)
    let visitor = BindingDiscovery(sourcePath: sourcePath, converter: converter)
    visitor.walk(syntaxTree)
    return SourceFileDiscovery(
        bindings: visitor.bindings,
        containerBindings: visitor.containerBindings,
        imports: visitor.imports,
        warnings: visitor.warnings,
        unannotatedExtensionProvides: visitor.unannotatedExtensionProvides,
        typealiases: visitor.typealiases,
        declaredTypeNames: visitor.declaredTypeNames
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
