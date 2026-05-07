import Testing

@testable import WireGenCore

@Suite("Discovery")
struct DiscoveryTests {
    /// Extract just the `@Singleton` bindings — preserves the
    /// pre-`@Provides` shape of these tests, which assert on
    /// `DiscoveredSingleton` fields directly.
    private func discoverSingletons(
        in source: String,
        sourcePath: String
    ) -> [DiscoveredSingleton] {
        discover(in: source, sourcePath: sourcePath).bindings.compactMap { binding in
            if case .singleton(let singleton) = binding { return singleton }
            return nil
        }
    }

    /// Extract just the `@Provides` bindings.
    private func discoverProviders(
        in source: String,
        sourcePath: String
    ) -> [DiscoveredProvider] {
        discover(in: source, sourcePath: sourcePath).bindings.compactMap { binding in
            if case .provider(let provider) = binding { return provider }
            return nil
        }
    }

    @Test func emptySourceFindsNoSingletons() {
        let result = discoverSingletons(in: "", sourcePath: "Empty.swift")
        #expect(result.isEmpty)
    }

    @Test func sourceWithoutAnyAnnotationsFindsNoSingletons() {
        let source = """
            struct Plain {
                var x: Int
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Plain.swift")
        #expect(result.isEmpty)
    }

    @Test func singletonOnStructIsDiscovered() {
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "A")
        #expect(result[0].typeKind == "struct")
        #expect(result[0].sourcePath == "A.swift")
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == "b")
        #expect(result[0].dependencies[0].type == "B")
        #expect(result[0].dependencies[0].kind == .injectProperty)
    }

    @Test func singletonOnClassIsDiscovered() {
        let source = """
            @Singleton
            final class A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].typeKind == "class")
    }

    @Test func singletonOnActorIsDiscovered() {
        let source = """
            @Singleton
            actor A {
                @Inject var b: B
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].typeKind == "actor")
    }

    @Test func singletonWithNoInjectsHasEmptyDependencies() {
        let source = """
            @Singleton
            struct A {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
    }

    @Test func singletonGenericParametersCaptured() {
        let source = """
            @Singleton
            struct Repository<Model> {
                @Inject var store: Store
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Repository.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "Repository")
        #expect(result[0].genericParameterNames == ["Model"])
    }

    @Test func singletonMultipleGenericParametersCaptured() {
        let source = """
            @Singleton
            struct Pair<Left, Right> {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Pair.swift")
        #expect(result.count == 1)
        #expect(result[0].genericParameterNames == ["Left", "Right"])
    }

    @Test func injectInitParametersTakePrecedenceOverProperties() {
        // When a type has both @Inject properties and an @Inject init, the
        // init's parameter list wins. (The macro flags this combination as
        // an error during compilation; WireGen is downstream of that and
        // takes a best-effort posture.)
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
                @Inject
                init(c: C) {
                    self.b = B(c: c)
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == "c")
        #expect(result[0].dependencies[0].type == "C")
        #expect(result[0].dependencies[0].kind == .injectInitParameter)
    }

    @Test func injectInitWithMultipleParametersPreservesOrder() {
        let source = """
            @Singleton
            struct A {
                @Inject
                init(first: First, second: Second, third: Third) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result[0].dependencies.map { $0.name } == ["first", "second", "third"])
        #expect(result[0].dependencies.map { $0.type } == ["First", "Second", "Third"])
    }

    @Test func multipleInjectPropertiesInOrder() {
        let source = """
            @Singleton
            struct A {
                @Inject var first: First
                @Inject var second: Second
                @Inject var third: Third
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "A.swift")
        #expect(result[0].dependencies.map { $0.name } == ["first", "second", "third"])
    }

    @Test func unannotatedTypeIsIgnored() {
        let source = """
            struct A {
                @Inject var b: B
            }

            @Singleton
            struct B {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Mixed.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "B")
    }

    @Test func multipleSingletonsInOneFile() {
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }

            @Singleton
            struct B {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "Both.swift")
        #expect(result.count == 2)
        #expect(Set(result.map { $0.typeName }) == ["A", "B"])
    }

    // MARK: - Parameter name edge cases

    @Test func injectInitWithWildcardParameterLabel() {
        // `init(_ a: A)` — wildcard external label. Wire captures `nil`
        // for the name so the type system forces code emission to
        // handle the "omit the label" case explicitly, rather than
        // sneaking through as a `"_"` sentinel that downstream might
        // accidentally emit literally.
        let source = """
            @Singleton
            struct X {
                @Inject
                init(_ a: A) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "X.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].name == nil)
        #expect(result[0].dependencies[0].type == "A")
    }

    @Test func injectInitWithExternalAndInternalLabels() {
        // `init(label internalName: A)` — both names set. The external
        // label "label" is what callers write at the call site, so
        // that's what Wire captures. The internal name "internalName"
        // is an implementation detail of the init body, irrelevant to
        // Wire's bootstrap codegen.
        let source = """
            @Singleton
            struct X {
                @Inject
                init(label internalName: A) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "X.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies[0].name == "label")
    }

    @Test func injectPropertyWithoutTypeAnnotationIsSkipped() {
        // `@Inject var x = SomeFactory.make()` — type-inferred property.
        // The macro would normally reject this; WireGen is downstream of
        // that and takes a best-effort posture: a property without a
        // type annotation can't be turned into an injection point.
        let source = """
            @Singleton
            struct X {
                @Inject var x = 5
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "X.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.isEmpty)
    }

    // MARK: - @Provides discovery

    @Test func providesOnTopLevelLetIsDiscovered() {
        let source = """
            @Provides let logger: Logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
        #expect(result[0].accessPath == "logger")
        #expect(result[0].form == .property)
        #expect(result[0].dependencies.isEmpty)
        #expect(result[0].sourcePath == "App.swift")
    }

    @Test func providesOnTopLevelFuncWithoutParametersIsDiscovered() {
        let source = """
            @Provides
            func makeLogger() -> Logger {
                Logger()
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
        #expect(result[0].accessPath == "makeLogger")
        #expect(result[0].form == .function)
        #expect(result[0].dependencies.isEmpty)
    }

    @Test func providesOnTopLevelFuncWithParametersBecomesDependencies() {
        let source = """
            @Provides
            func makeRepository(table: TaskTable, logger: Logger) -> Repository {
                Repository(table: table, logger: logger)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 2)
        #expect(result[0].dependencies[0].name == "table")
        #expect(result[0].dependencies[0].type == "TaskTable")
        #expect(result[0].dependencies[0].kind == .providerFunctionParameter)
        #expect(result[0].dependencies[1].name == "logger")
        #expect(result[0].dependencies[1].type == "Logger")
    }

    @Test func providesOnStaticLetCapturesEnclosingTypeInAccessPath() {
        let source = """
            enum Config {
                @Provides static let dbURL: URL = URL(string: "...")!
            }
            """
        let result = discoverProviders(in: source, sourcePath: "Config.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "URL")
        #expect(result[0].accessPath == "Config.dbURL")
        #expect(result[0].form == .property)
    }

    @Test func providesOnStaticFuncCapturesEnclosingTypeInAccessPath() {
        let source = """
            struct AppConfig {
                @Provides
                static func makeClient() -> HTTPClient {
                    HTTPClient()
                }
            }
            """
        let result = discoverProviders(in: source, sourcePath: "AppConfig.swift")
        #expect(result.count == 1)
        #expect(result[0].accessPath == "AppConfig.makeClient")
        #expect(result[0].form == .function)
    }

    @Test func providesNestedInsideTypesProducesDottedAccessPath() {
        // Caseless-enum-as-namespace pattern with nested namespacing.
        // Access path joins enclosing types with `.`, just like Swift
        // call-site syntax.
        let source = """
            enum Outer {
                enum Inner {
                    @Provides static let foo: Foo = Foo()
                }
            }
            """
        let result = discoverProviders(in: source, sourcePath: "N.swift")
        #expect(result.count == 1)
        #expect(result[0].accessPath == "Outer.Inner.foo")
    }

    @Test func providesOnInstanceMemberIsSkipped() {
        // Instance members have no resolvable construction path, so
        // `@Provides` on them is silently ignored.
        let source = """
            struct AppConfig {
                @Provides let logger: Logger = Logger()
            }
            """
        let result = discoverProviders(in: source, sourcePath: "AppConfig.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetInferredFromConstructorCallIsDiscovered() {
        // Idiomatic Swift form: `let x = Foo()` with no annotation.
        // The bound type is inferred from the called constructor.
        let source = """
            @Provides let logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
        #expect(result[0].accessPath == "logger")
    }

    @Test func providesLetInferredFromGenericConstructorCall() {
        // `let x = Foo<Bar>()` — the generic specialisation is part of
        // the inferred type.
        let source = """
            @Provides let repo = Repository<TaskTable>()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Repository<TaskTable>")
    }

    @Test func providesLetWithDotInitFormIsDiscovered() {
        // `let x: Type = .init()` — annotation present, RHS isn't read.
        // This was already supported but pin the behaviour with a test.
        let source = """
            @Provides let logger: Logger = .init()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "Logger")
    }

    @Test func providesLetFromMemberAccessIsSkipped() {
        // `let x = Foo.shared` — we can't tell what type `shared`
        // resolves to without running type inference. Skip silently;
        // the user can add an explicit annotation.
        let source = """
            @Provides let logger = Logger.shared
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetFromLowercaseFunctionCallIsSkipped() {
        // `let x = makeFoo()` — calls a function. By Swift convention
        // a lowercase-first identifier isn't a type, so we don't
        // misidentify the function name as the bound type.
        let source = """
            @Provides let logger = makeLogger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetFromLiteralIsSkipped() {
        // `let x = 42` — non-call initializers aren't recognised.
        let source = """
            @Provides let answer = 42
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesLetTypeAnnotationTakesPrecedenceOverConstructorCall() {
        // When both forms are present, the user's annotation is the
        // declared bound type — they may have widened to a protocol or
        // existential that the RHS conforms to.
        let source = """
            @Provides let logger: any Logger = AppLogger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "any Logger")
    }

    @Test func providesOnFuncCapturesGenericParameters() {
        // Generic functions are skipped from the graph at construction
        // time (deferred until concrete specialisation lands), but
        // discovery captures the names so the skip can be reported.
        let source = """
            @Provides
            func makeRepository<T: TaskTable>(table: T) -> Repository<T> {
                Repository(table: table)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].genericParameterNames == ["T"])
    }

    @Test func providesOnVoidReturningFuncIsSkipped() {
        // A `@Provides func` with no return clause produces nothing
        // injectable. The build plugin silently skips it; the macro
        // could later turn this into a diagnostic, but for now it's a
        // no-op rather than a hard error.
        let source = """
            @Provides
            func sideEffect() {
                print("hello")
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.isEmpty)
    }

    @Test func providesPreservesGenericInstantiationInBoundType() {
        // Concrete generic instantiations as the bound type are
        // supported (the codegen sanitisation handles them when
        // building the property name).
        let source = """
            @Provides
            func makeRepository(table: TaskTable)
                -> DynamoDBRepository<TaskTable>
            {
                DynamoDBRepository(table: table)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].boundType == "DynamoDBRepository<TaskTable>")
    }

    @Test func mixedSingletonsAndProvidersInOneFile() {
        let source = """
            @Provides let logger: Logger = Logger()

            @Singleton
            struct UserService {
                @Inject var logger: Logger
            }

            enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let bindings = discover(in: source, sourcePath: "Mixed.swift").bindings
        #expect(bindings.count == 3)
        let singletons = bindings.compactMap { binding -> DiscoveredSingleton? in
            if case .singleton(let s) = binding { return s }
            return nil
        }
        let providers = bindings.compactMap { binding -> DiscoveredProvider? in
            if case .provider(let p) = binding { return p }
            return nil
        }
        #expect(singletons.count == 1)
        #expect(singletons[0].typeName == "UserService")
        #expect(providers.count == 2)
        #expect(Set(providers.map { $0.accessPath }) == ["logger", "Config.baseURL"])
    }

    // MARK: - Import discovery

    @Test func discoverImportsFindsPlainImports() {
        let source = """
            import Foundation
            import OSLog

            @Provides let logger: Logger = Logger()
            """
        let imports = discover(in: source, sourcePath: "").imports
        #expect(imports == ["import Foundation", "import OSLog"])
    }

    @Test func discoverImportsPreservesAccessModifiersVerbatim() {
        // @testable, @_implementationOnly, @preconcurrency, etc. need
        // to be propagated verbatim — silently dropping them changes
        // semantics in the generated file.
        let source = """
            import Foundation
            @testable import Internals
            @_implementationOnly import OSLog
            """
        let imports = discover(in: source, sourcePath: "").imports
        #expect(imports.contains("import Foundation"))
        #expect(imports.contains("@testable import Internals"))
        #expect(imports.contains("@_implementationOnly import OSLog"))
    }

    @Test func discoverImportsCapturesScopedImports() {
        // `import struct Foundation.URL` form is supported by Swift
        // and must be preserved as-is.
        let source = """
            import struct Foundation.URL
            import func Foundation.exit
            """
        let imports = discover(in: source, sourcePath: "").imports
        #expect(imports.contains("import struct Foundation.URL"))
        #expect(imports.contains("import func Foundation.exit"))
    }

    @Test func discoverImportsReturnsEmptyForFileWithNoImports() {
        let source = """
            @Singleton
            struct A {
            }
            """
        let imports = discover(in: source, sourcePath: "").imports
        #expect(imports.isEmpty)
    }

    // MARK: - renderDiscoveryReport

    @Test func discoveryReportHeaderAndCountWithEmptyInput() {
        let report = renderDiscoveryReport(perFile: [])
        #expect(report.contains("WireGen discovery report"))
        #expect(report.contains("discovered 0 binding(s) across 0 source file(s)"))
    }

    @Test func discoveryReportSkipsFilesWithNoBindings() {
        // Files that contained no bindings should not appear in the
        // report body; they still count toward "source file(s)" though.
        let item: DiscoveredBinding = .singleton(
            DiscoveredSingleton(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                sourcePath: "Found.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [
            (path: "Empty.swift", items: []),
            (path: "Found.swift", items: [item]),
        ])
        #expect(!report.contains("Empty.swift"))
        #expect(report.contains("Found.swift"))
        #expect(report.contains("discovered 1 binding(s) across 2 source file(s)"))
    }

    @Test func discoveryReportRendersSingletonGenerics() {
        let item: DiscoveredBinding = .singleton(
            DiscoveredSingleton(
                typeName: "Repository",
                typeKind: "struct",
                genericParameterNames: ["Model"],
                dependencies: [],
                sourcePath: "R.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "R.swift", items: [item])])
        #expect(report.contains("@Singleton struct Repository<Model>"))
    }

    @Test func discoveryReportRendersInjectPropertyDependency() {
        let item: DiscoveredBinding = .singleton(
            DiscoveredSingleton(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(name: "b", type: "B", kind: .injectProperty)
                ],
                sourcePath: "A.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("b: B"))
        #expect(report.contains("@Inject property"))
    }

    @Test func discoveryReportRendersInjectInitParameterDependency() {
        let item: DiscoveredBinding = .singleton(
            DiscoveredSingleton(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(name: "b", type: "B", kind: .injectInitParameter)
                ],
                sourcePath: "A.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("@Inject init parameter"))
    }

    @Test func discoveryReportRendersProviderProperty() {
        let item: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Logger",
                accessPath: "logger",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                sourcePath: "App.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "App.swift", items: [item])])
        #expect(report.contains("@Provides let logger -> Logger"))
    }

    @Test func discoveryReportRendersProviderFunctionWithParameters() {
        let item: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Repository",
                accessPath: "makeRepository",
                form: .function,
                dependencies: [
                    DependencyParameter(
                        name: "table",
                        type: "TaskTable",
                        kind: .providerFunctionParameter
                    )
                ],
                genericParameterNames: [],
                sourcePath: "App.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "App.swift", items: [item])])
        #expect(report.contains("@Provides func makeRepository -> Repository"))
        #expect(report.contains("table: TaskTable"))
        #expect(report.contains("@Provides function parameter"))
    }

    @Test func discoveryReportShowsNoDependenciesNoticeWhenEmpty() {
        let item: DiscoveredBinding = .singleton(
            DiscoveredSingleton(
                typeName: "A",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                sourcePath: "A.swift"
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("(no dependencies)"))
    }
}
