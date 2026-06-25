import Testing

@testable import WireGenCore

/// Iteration 7a: single-`BindingKey` tracking. These pin that
/// `BindingKey<T>` declarations are captured with the right canonical
/// reference text, phantom type argument, and effective access — and
/// that the missing-key diagnostic fires for a reference to an undeclared
/// key while leaving declared single keys and multibinding-key references
/// alone.
@Suite("BindingKey discovery")
struct BindingKeyDiscoveryTests {
    private func keys(in source: String) -> [DiscoveredBindingKey] {
        discover(in: source, sourcePath: "Keys.swift", module: testModule).bindingKeys
    }

    // MARK: - Scanner

    @Test func bindingKeyOnExtensionCapturesReferenceAndType() throws {
        let source = """
            extension Database {
                static let primary = BindingKey<Database>()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(keys(in: source).count == 1)
        #expect(key.keyReference == "Database.primary")
        #expect(key.typeArgument == "Database")
    }

    @Test func bindingKeyFromExplicitAnnotation() throws {
        let source = """
            enum Keys {
                static let alternate: BindingKey<AppName> = BindingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.keyReference == "Keys.alternate")
        #expect(key.typeArgument == "AppName")
    }

    @Test func moduleScopeBindingKeyHasUnqualifiedReference() throws {
        let source = "let primary = BindingKey<Foo>()"
        let key = try #require(keys(in: source).first)
        #expect(key.keyReference == "primary")
        #expect(key.typeArgument == "Foo")
    }

    @Test func bindingKeyWithoutGenericsRecordsNilType() throws {
        let source = """
            enum Keys {
                static let opaque = BindingKey()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.keyReference == "Keys.opaque")
        #expect(key.typeArgument == nil)
    }

    @Test func effectiveAccessFoldsEnclosingType() throws {
        let source = """
            enum Keys {
                public static let primary = BindingKey<Database>()
            }
            """
        // The key is `public` but its enclosing `enum Keys` is `internal`,
        // so the effective access is `internal` (most restrictive wins).
        let key = try #require(keys(in: source).first)
        #expect(key.accessLevel == .internal)
    }

    @Test func nonKeyDeclarationsAreIgnored() {
        let source = """
            enum Keys {
                static let services = CollectedKey<any Service>()
                static let count = 3
            }
            """
        // A multibinding key and a plain constant are not single BindingKeys.
        #expect(keys(in: source).isEmpty)
    }

    // MARK: - Missing-key diagnostic

    private func provider(_ boundType: String, key: String?) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: "make\(boundType)",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("Keys.swift"),
                keyIdentifier: key,
                originModule: testModule
            )
        )
    }

    private func consumer(dependencyKey: String?) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Consumer",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "dep",
                        type: "Database",
                        kind: .injectProperty,
                        location: mockLocation("Keys.swift"),
                        keyIdentifier: dependencyKey
                    )
                ],
                location: mockLocation("Keys.swift"),
                originModule: testModule
            )
        )
    }

    @Test func undeclaredKeyOnConsumerIsAnError() {
        let diagnostics = unknownBindingKeyDiagnostics(
            bindingsByPartition: [Partition(): [consumer(dependencyKey: "Database.primary")]],
            declaredKeyReferences: []
        )
        #expect(diagnostics.contains { $0.message.contains("'Database.primary' is referenced but never declared") })
    }

    @Test func undeclaredKeyOnProviderIsAnError() {
        let diagnostics = unknownBindingKeyDiagnostics(
            bindingsByPartition: [Partition(): [provider("Database", key: "Database.primary")]],
            declaredKeyReferences: []
        )
        #expect(diagnostics.contains { $0.message.contains("never declared") })
    }

    @Test func declaredSingleKeyDoesNotError() {
        let diagnostics = unknownBindingKeyDiagnostics(
            bindingsByPartition: [
                Partition(): [
                    provider("Database", key: "Database.primary"),
                    consumer(dependencyKey: "Database.primary"),
                ]
            ],
            declaredKeyReferences: ["Database.primary"]
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func multibindingKeyReferenceDoesNotError() {
        // An aggregate consumer references a multibinding key the same way
        // a single-key consumer does; with that key in the unified declared
        // set, no missing-key error fires.
        let diagnostics = unknownBindingKeyDiagnostics(
            bindingsByPartition: [Partition(): [consumer(dependencyKey: "App.services")]],
            declaredKeyReferences: ["App.services"]
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func unkeyedBindingsDoNotError() {
        let diagnostics = unknownBindingKeyDiagnostics(
            bindingsByPartition: [
                Partition(): [provider("Database", key: nil), consumer(dependencyKey: nil)]
            ],
            declaredKeyReferences: []
        )
        #expect(diagnostics.isEmpty)
    }

    // MARK: - End-to-end (real parse → scanner → diagnostic)

    /// Compose the scanner and the diagnostic the way WireGen does: parse
    /// source, union the declared single + multibinding keys, then run the
    /// missing-key check over the discovered bindings.
    private func missingKeyDiagnostics(in source: String) -> [Diagnostic] {
        let discovery = discover(in: source, sourcePath: "Keys.swift", module: testModule)
        let declared = Set(discovery.bindingKeys.map(\.keyReference))
            .union(discovery.multibindingKeys.map(\.keyReference))
        return unknownBindingKeyDiagnostics(
            bindingsByPartition: discovery.allBindings,
            declaredKeyReferences: declared
        )
    }

    @Test func endToEndUndeclaredKeyErrors() {
        // `Database.primary` is referenced by the keyed consumer but no
        // `BindingKey<Database>` declares it.
        let source = """
            @Provides
            let db: Database = Database()

            @Singleton(allowUnused: true)
            struct Consumer {
                @Inject(Database.primary) var db: Database
            }
            """
        #expect(
            missingKeyDiagnostics(in: source)
                .contains { $0.message.contains("'Database.primary' is referenced but never declared") }
        )
    }

    @Test func endToEndDeclaredKeyPasses() {
        // The canonical keyed pattern: a declared key, a keyed producer,
        // and a keyed consumer all referencing `Database.primary`.
        let source = """
            extension Database {
                static let primary = BindingKey<Database>()
            }

            @Provides(Database.primary)
            let primaryDB: Database = Database()

            @Singleton(allowUnused: true)
            struct Consumer {
                @Inject(Database.primary) var db: Database
            }
            """
        #expect(missingKeyDiagnostics(in: source).isEmpty)
    }
}
