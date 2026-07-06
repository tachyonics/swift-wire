/// A read-only, framework-agnostic view of a generated Wire graph, returned by the
/// graph's `introspect()`. The data is baked in at codegen — Wire is compile-time DI,
/// so the wiring is fully known without runtime reflection. `Codable`, so adapters can
/// serialise it (e.g. WireHummingbird's introspection endpoint).
public struct WiringModel: Sendable, Codable {
    /// Every binding the graph produces, in construction (topological) order.
    public let bindings: [BindingInfo]

    public init(bindings: [BindingInfo]) {
        self.bindings = bindings
    }
}

/// One binding in the graph.
public struct BindingInfo: Sendable, Codable {
    /// The bound type (graph identity) — e.g. `Logger`, `some TaskRepo`, `[any Service]`.
    public let type: String
    /// The binding key, if keyed (`@Provides(Key)`, a multibinding key), else nil.
    public let key: String?
    /// What produces it.
    public let kind: BindingKind
    /// The scope it lives in (the seed type), or nil for app-scoped.
    public let scope: String?
    /// What it consumes — a type/provider's injected dependencies, or the contributors
    /// collated into an aggregate.
    public let dependencies: [DependencyEdge]
    /// Where it's declared — the origin module, source file, and line. For a
    /// synthesised aggregate, the location of its multibinding key.
    public let location: SourceLocation

    public init(
        type: String,
        key: String?,
        kind: BindingKind,
        scope: String?,
        dependencies: [DependencyEdge],
        location: SourceLocation
    ) {
        self.type = type
        self.key = key
        self.kind = kind
        self.scope = scope
        self.dependencies = dependencies
        self.location = location
    }
}

/// Where a binding is declared.
public struct SourceLocation: Sendable, Codable {
    /// The module the binding was declared in.
    public let module: String
    /// The source file.
    public let file: String
    /// The line within the file.
    public let line: Int

    public init(module: String, file: String, line: Int) {
        self.module = module
        self.file = file
        self.line = line
    }
}

/// What produces a binding — an app-scoped `@Singleton`, a seed-scoped `@Scoped`, a
/// `@Provides`, or a multibinding aggregate.
public enum BindingKind: String, Sendable, Codable {
    case singleton
    case scoped
    case provider
    case aggregate
}

/// A dependency edge — one thing a binding consumes.
public struct DependencyEdge: Sendable, Codable {
    /// The consumed type.
    public let type: String
    /// The key, if the dependency is keyed, else nil.
    public let key: String?

    public init(type: String, key: String?) {
        self.type = type
        self.key = key
    }
}
