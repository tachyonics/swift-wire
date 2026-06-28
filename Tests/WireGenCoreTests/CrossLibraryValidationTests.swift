import Testing

@testable import WireGenCore

/// Iteration 7e: cross-library validation. After 7c/7d the plugin merges
/// the consumer's bindings and every activated library's bindings into one
/// graph before validating, so missing-binding / ambiguity / resolution
/// all span the activated set. These tests simulate that merge directly —
/// `discover` each module's source under its own module name, concatenate
/// the bindings, then run the real graph build + validation rendering —
/// without needing a multi-package on-disk fixture (that's 7g's harness).
@Suite("CrossLibraryValidation")
struct CrossLibraryValidationTests {
    /// Discover several `(module, source)` inputs, merge their default-graph
    /// bindings, build the graph, and return the rendered validation errors
    /// ("" when the graph is valid).
    private func validateMerged(_ modules: [(module: String, source: String)]) -> String {
        var bindings: [DiscoveredBinding] = []
        var typealiases: [DiscoveredTypealias] = []
        for (index, entry) in modules.enumerated() {
            let discovery = discover(
                in: entry.source,
                sourcePath: "\(entry.module)\(index).swift",
                module: entry.module
            )
            bindings += discovery.bindings
            typealiases += discovery.typealiases
        }
        let result = buildDependencyGraph(from: bindings, typealiases: typealiases)
        return result.outcome.validationErrors.map { renderValidationErrors($0) } ?? ""
    }

    @Test func crossLibraryDependencyResolvesAcrossModules() {
        // A consumer in module `App` resolves a `Logger` provided by module
        // `Lib` — the merge makes the library's binding satisfy the
        // consumer's `@Inject`, so there are no validation errors.
        let lib = "@Provides let logger: Logger = Logger()"
        let app = """
            @Singleton
            struct Consumer {
                @Inject var logger: Logger
            }
            """
        #expect(validateMerged([("Lib", lib), ("App", app)]).isEmpty)
    }

    @Test func crossLibraryMissingBindingFires() {
        // The consumer `@Inject`s a type no activated module provides — a
        // missing-binding error across the merged set.
        let lib = "@Provides let logger: Logger = Logger()"
        let app = """
            @Singleton
            struct Consumer {
                @Inject var missing: Missing
            }
            """
        let rendered = validateMerged([("Lib", lib), ("App", app)])
        #expect(rendered.contains("no binding produces"))
        #expect(rendered.contains("Missing"))
    }

    @Test func crossLibraryAmbiguityNamesConflictingModules() {
        // Two activated libraries each bind `Cache` (unkeyed) — ambiguous.
        // The diagnostic names the origin module of each conflicting
        // binding so the user can see which libraries collide.
        let libA = "@Provides let a: Cache = Cache()"
        let libB = "@Provides let b: Cache = Cache()"
        let rendered = validateMerged([("LibA", libA), ("LibB", libB)])
        #expect(rendered.contains("has multiple bindings"))
        #expect(rendered.contains("module 'LibA'"))
        #expect(rendered.contains("module 'LibB'"))
    }

    /// Run the unknown-key check over several merged modules' discovery —
    /// the missing-key check is "no such key in the parse set," and the
    /// parse set is the union across activated modules.
    private func unknownKeyDiagnostics(_ modules: [(module: String, source: String)]) -> [Diagnostic] {
        var allBindings: [Partition: [DiscoveredBinding]] = [:]
        var declaredKeys: Set<String> = []
        for (index, entry) in modules.enumerated() {
            let discovery = discover(
                in: entry.source,
                sourcePath: "\(entry.module)\(index).swift",
                module: entry.module
            )
            for (partition, bindings) in discovery.allBindings {
                allBindings[partition, default: []] += bindings
            }
            declaredKeys.formUnion(discovery.bindingKeys.map(\.keyReference))
            declaredKeys.formUnion(discovery.multibindingKeys.map(\.keyReference))
        }
        return unknownBindingKeyDiagnostics(
            bindingsByPartition: allBindings,
            declaredKeyReferences: declaredKeys
        )
    }

    @Test func crossLibraryKeyReferenceResolves() {
        // A `BindingKey` declared in module `Lib` resolves a keyed
        // `@Inject` in module `App` — the parse set spans the activated
        // modules, so the missing-key check loosens automatically.
        let lib = """
            extension Database {
                static let primary = BindingKey<Database>()
            }

            @Provides(Database.primary)
            let primaryDB: Database = Database()
            """
        let app = """
            @Singleton
            struct Consumer {
                @Inject(Database.primary) var db: Database
            }
            """
        #expect(unknownKeyDiagnostics([("Lib", lib), ("App", app)]).isEmpty)
    }

    @Test func sameModuleDuplicateKeepsOriginalWording() {
        // A same-module duplicate is still ambiguous, but naming the module
        // would be noise — the original wording is preserved (no "module
        // '...'" suffix), so existing single-module diagnostics don't churn.
        let source = """
            @Provides let a: Cache = Cache()
            @Provides let b: Cache = Cache()
            """
        let rendered = validateMerged([("App", source)])
        #expect(rendered.contains("has multiple bindings"))
        #expect(!rendered.contains("module '"))
    }
}
