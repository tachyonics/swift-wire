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

    // MARK: - @Container discovery

    @Test func providesInsideContainerRoutedToContainerBucket() {
        // @Provides inside a @Container enum lands in the container's
        // bucket, not the default-graph bucket.
        let source = """
            @Container
            enum TestContainer {
                @Provides static let logger: Logger = Logger()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        #expect(result.bindings.isEmpty)
        #expect(result.containerBindings.keys.sorted() == ["TestContainer"])
        let testContainerBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testContainerBindings.count == 1)
        if case .provider(let provider) = testContainerBindings[0] {
            #expect(provider.boundType == "Logger")
            #expect(provider.accessPath == "TestContainer.logger")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func nestedSingletonInsideContainerRoutedToContainerBucket() {
        // A @Singleton declared inside a @Container belongs to that
        // container's graph, not the default graph. The qualified
        // type name captures the full enclosing path so codegen can
        // construct the type from module scope.
        let source = """
            @Container
            enum TestContainer {
                @Singleton
                struct MockService {
                    @Inject var logger: Logger
                }
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        #expect(result.bindings.isEmpty)
        let testContainerBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testContainerBindings.count == 1)
        if case .singleton(let singleton) = testContainerBindings[0] {
            #expect(singleton.typeName == "MockService")
            #expect(singleton.qualifiedTypeName == "TestContainer.MockService")
            #expect(singleton.dependencies.first?.type == "Logger")
        } else {
            Issue.record("expected singleton binding")
        }
    }

    @Test func topLevelSingletonHasQualifiedTypeNameEqualToTypeName() {
        // For a `@Singleton` at module scope, the qualified type name
        // is just the simple name — codegen needs no enclosing prefix.
        let source = """
            @Singleton
            struct UserService {
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserService.swift")
        #expect(result.count == 1)
        #expect(result[0].typeName == "UserService")
        #expect(result[0].qualifiedTypeName == "UserService")
    }

    @Test func bindingsInNonContainerEnclosingTypeStayInDefaultGraph() {
        // Static @Provides on a non-@Container enum continues to feed
        // the default graph (preserves 2a behaviour).
        let source = """
            enum Config {
                @Provides static let baseURL: URL = URL(string: "...")!
            }
            """
        let result = discover(in: source, sourcePath: "Config.swift")
        #expect(result.bindings.count == 1)
        #expect(result.containerBindings.isEmpty)
    }

    @Test func multipleContainersProduceIndependentBuckets() {
        let source = """
            @Container
            enum ProdContainer {
                @Provides static let logger: Logger = Logger()
            }

            @Container
            enum TestContainer {
                @Provides static let logger: Logger = MockLogger()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        #expect(result.bindings.isEmpty)
        #expect(result.containerBindings.keys.sorted() == ["ProdContainer", "TestContainer"])
        #expect(result.containerBindings["ProdContainer"]?.count == 1)
        #expect(result.containerBindings["TestContainer"]?.count == 1)
    }

    @Test func mixedContainerAndModuleScopeBindingsArePartitioned() {
        let source = """
            @Provides let appName: AppName = AppName(value: "default")

            @Singleton
            struct UserService {
                @Inject var logger: Logger
            }

            @Container
            enum TestContainer {
                @Provides static let appName: AppName = AppName(value: "test")
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        // Default graph: module-scope @Provides + module-scope @Singleton
        #expect(result.bindings.count == 2)
        // Container: just its @Provides
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 1)
        if case .provider(let provider) = testBindings[0] {
            #expect(provider.accessPath == "TestContainer.appName")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func providesInUnannotatedExtensionFallsThroughToDefault() {
        // An extension without its own `@Container` annotation is just
        // an extension — its bindings fall through to the default
        // graph with a `Foo.member`-style access path. Even when the
        // extended type has a `@Container` primary declaration, the
        // extension itself doesn't carry container semantics.
        let source = """
            @Container
            enum TestContainer {
                @Provides static let logger: Logger = Logger()
            }

            extension TestContainer {
                @Provides static let extra: Extra = Extra()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        // The container's primary `@Provides` lands in the container.
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 1)
        if case .provider(let provider) = testBindings[0] {
            #expect(provider.accessPath == "TestContainer.logger")
        } else {
            Issue.record("expected provider binding")
        }
        // The extension's `@Provides` falls through to default with
        // a dotted access path. (Iteration 3 will surface a warning
        // here pointing the user at `@Container extension` or moving
        // the binding into the primary declaration.)
        #expect(result.bindings.count == 1)
        if case .provider(let provider) = result.bindings[0] {
            #expect(provider.accessPath == "TestContainer.extra")
            #expect(provider.boundType == "Extra")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func providesInContainerAnnotatedExtensionMergesIntoContainer() {
        // `@Container extension Foo { ... }` opts the extension into
        // Foo's container — the extension's bindings merge with the
        // primary `@Container enum Foo` declaration's bindings.
        let source = """
            @Container
            enum TestContainer {
                @Provides static let logger: Logger = Logger()
            }

            @Container
            extension TestContainer {
                @Provides static let extra: Extra = Extra()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        #expect(result.bindings.isEmpty)
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 2)
        let accessPaths = Set(
            testBindings.compactMap { binding -> String? in
                if case .provider(let provider) = binding {
                    return provider.accessPath
                }
                return nil
            }
        )
        #expect(accessPaths == ["TestContainer.logger", "TestContainer.extra"])
    }

    @Test func containerOnStructRoutesBindingsToContainer() {
        // The README's canonical pattern is `@Container enum`, but
        // any type kind that can carry `static` members works. A
        // `@Container struct` namespace routes its static `@Provides`
        // into the container the same way an enum would.
        let source = """
            @Container
            struct AppConfig {
                @Provides static let logger: Logger = Logger()
            }
            """
        let result = discover(in: source, sourcePath: "AppConfig.swift")
        #expect(result.bindings.isEmpty)
        let bindings = result.containerBindings["AppConfig"] ?? []
        #expect(bindings.count == 1)
        if case .provider(let provider) = bindings.first {
            #expect(provider.accessPath == "AppConfig.logger")
        } else {
            Issue.record("expected provider binding")
        }
    }

    @Test func containerOnClassRoutesBindingsToContainer() {
        let source = """
            @Container
            class TestContainer {
                @Provides static let mockLogger: Logger = MockLogger()
            }
            """
        let result = discover(in: source, sourcePath: "TestContainer.swift")
        let bindings = result.containerBindings["TestContainer"] ?? []
        #expect(bindings.count == 1)
    }

    @Test func containerOnActorRoutesBindingsToContainer() {
        let source = """
            @Container
            actor RuntimeConfig {
                @Provides static let buildNumber: Int = 42
            }
            """
        let result = discover(in: source, sourcePath: "RuntimeConfig.swift")
        let bindings = result.containerBindings["RuntimeConfig"] ?? []
        #expect(bindings.count == 1)
    }

    @Test func containerAnnotatedExtensionWithoutPrimaryDeclarationStillContributes() {
        // The `@Container` annotation on an extension is sufficient on
        // its own — the extended type doesn't need a primary
        // `@Container` declaration in the same source. (Whether one
        // exists in another source file is a cross-file question that
        // the build plugin handles by aggregating per-file results.)
        let source = """
            @Container
            extension SomeType {
                @Provides static let value: Value = Value()
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        #expect(result.bindings.isEmpty)
        let bindings = result.containerBindings["SomeType"] ?? []
        #expect(bindings.count == 1)
    }

    @Test func providesInsideHelperTypeNestedInContainerStillRoutesToContainer() {
        // A non-@Container helper struct nested inside a @Container
        // inherits the container scope — its bindings still belong to
        // the enclosing container's graph.
        let source = """
            @Container
            enum TestContainer {
                struct Helper {
                    @Provides static let value: Value = Value()
                }
            }
            """
        let result = discover(in: source, sourcePath: "App.swift")
        #expect(result.bindings.isEmpty)
        let testBindings = result.containerBindings["TestContainer"] ?? []
        #expect(testBindings.count == 1)
        if case .provider(let provider) = testBindings[0] {
            #expect(provider.accessPath == "TestContainer.Helper.value")
        } else {
            Issue.record("expected provider binding")
        }
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
                location: WireGenCore.SourceLocation(file: "Found.swift", line: 1, column: 1)
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
                location: WireGenCore.SourceLocation(file: "R.swift", line: 1, column: 1)
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
                    DependencyParameter(
                        name: "b",
                        type: "B",
                        kind: .injectProperty,
                        location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
                    )
                ],
                location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
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
                    DependencyParameter(
                        name: "b",
                        type: "B",
                        kind: .injectInitParameter,
                        location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
                    )
                ],
                location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
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
                location: WireGenCore.SourceLocation(file: "App.swift", line: 1, column: 1)
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
                        kind: .providerFunctionParameter,
                        location: WireGenCore.SourceLocation(file: "App.swift", line: 1, column: 1)
                    )
                ],
                genericParameterNames: [],
                location: WireGenCore.SourceLocation(file: "App.swift", line: 1, column: 1)
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
                location: WireGenCore.SourceLocation(file: "A.swift", line: 1, column: 1)
            )
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("(no dependencies)"))
    }

    // MARK: - Keyed @Provides / @Inject

    @Test func providesWithoutKeyArgumentHasNilKeyIdentifier() {
        // Sanity-check the default — unkeyed `@Provides` produces a
        // binding with `keyIdentifier == nil`. Existing tests cover this
        // implicitly; making it explicit pins the contract.
        let source = """
            @Provides let logger: Logger = Logger()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].keyIdentifier == nil)
    }

    @Test func providesWithMemberAccessKeyExtractsCanonicalText() {
        // `@Provides(Database.primary)` — the canonical key is the
        // trimmed text of the argument expression. That's what other
        // bindings/consumers must match against.
        let source = """
            @Provides(Database.primary)
            let primaryDB: Database = Database()
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].keyIdentifier == "Database.primary")
    }

    @Test func providesFunctionWithKeyExtractsCanonicalText() {
        // Same shape, but on a `@Provides func` — the key annotation
        // sits on the function declaration, not on individual params.
        let source = """
            @Provides(Database.primary)
            func makePrimaryDB() -> Database {
                Database()
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].keyIdentifier == "Database.primary")
    }

    @Test func injectPropertyWithKeyExtractsCanonicalText() {
        // `@Inject(Database.primary) var db: Database` — the consumer-
        // side annotation. Should propagate to the resulting
        // `DependencyParameter.keyIdentifier` so graph resolution can
        // match keyed slot.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject(Database.primary) var db: Database
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserRepo.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 1)
        #expect(result[0].dependencies[0].keyIdentifier == "Database.primary")
    }

    @Test func injectInitParameterWithKeyExtractsCanonicalText() {
        // Per-parameter `@Inject(<key>)` on an `@Inject`-marked init.
        // The init-level `@Inject` (no args) marks the init as canonical;
        // per-parameter `@Inject(<key>)` keys that specific dep.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject
                init(@Inject(Database.primary) db: Database, logger: Logger) {
                }
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserRepo.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 2)
        #expect(result[0].dependencies[0].name == "db")
        #expect(result[0].dependencies[0].keyIdentifier == "Database.primary")
        // Unkeyed dep stays unkeyed.
        #expect(result[0].dependencies[1].name == "logger")
        #expect(result[0].dependencies[1].keyIdentifier == nil)
    }

    @Test func providesFunctionParameterWithKeyExtractsCanonicalText() {
        // The same per-parameter `@Inject(<key>)` keying applies to
        // `@Provides func` parameters — they're deps just like
        // `@Inject` init parameters.
        let source = """
            @Provides
            func makeRepo(@Inject(Database.primary) db: Database, logger: Logger) -> Repository {
                Repository(db: db, logger: logger)
            }
            """
        let result = discoverProviders(in: source, sourcePath: "App.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies.count == 2)
        #expect(result[0].dependencies[0].keyIdentifier == "Database.primary")
        #expect(result[0].dependencies[1].keyIdentifier == nil)
    }

    @Test func bareIdentifierKeyExtractsAsIs() {
        // File-scope key declarations (`let primary = BindingKey<Foo>()`)
        // referenced bare. Canonical key is just "primary". Cross-file
        // conflicts on bare keys get reported as duplicates by the
        // graph; that's the expected behavior.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject(primary) var db: Database
            }
            """
        let result = discoverSingletons(in: source, sourcePath: "UserRepo.swift")
        #expect(result.count == 1)
        #expect(result[0].dependencies[0].keyIdentifier == "primary")
    }

    // MARK: - Warnings

    @Test func containerCombinedWithSingletonEmitsWarning() {
        // A type with both `@Container` and `@Singleton` ends up as
        // both a binding in the default graph and a grouping for its
        // own container — almost always a user error. Warn at the
        // type's name with a remedy suggestion.
        let source = """
            @Container
            @Singleton
            struct Mixed {
                @Inject var x: X
            }
            """
        let result = discover(in: source, sourcePath: "Mixed.swift")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@Container and @Singleton"))
        #expect(result.warnings[0].location.file == "Mixed.swift")
    }

    @Test func plainTypeDeclWithoutContainerEmitsNoWarning() {
        // Sanity check — a normal `@Singleton struct Foo` with no
        // `@Container` doesn't fire the warning.
        let source = """
            @Singleton
            struct Foo {
                @Inject var bar: Bar
            }
            """
        let result = discover(in: source, sourcePath: "Foo.swift")
        #expect(result.warnings.isEmpty)
    }

    @Test func injectInitInExtensionEmitsWarning() {
        // `@Inject` on an extension init is silently ignored by the
        // `@Singleton` macro (which only sees the primary declaration).
        // Warn at the init site with a fix-it suggestion.
        let source = """
            @Singleton
            struct Foo {
                @Inject var bar: Bar
            }

            extension Foo {
                @Inject init(custom: String) {
                }
            }
            """
        let result = discover(in: source, sourcePath: "Foo.swift")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@Inject on an extension init"))
        #expect(result.warnings[0].message.contains("'Foo'"))
    }

    @Test func unannotatedExtensionProvidesIsRecordedAsCandidate() {
        // The visitor records `@Provides` inside unannotated
        // extensions as candidate warnings — WireGen does the cross-
        // file resolution against the `@Container`-name set. This
        // test pins the candidate-collection step.
        let source = """
            extension AppConfig {
                @Provides static let logLevel: String = "info"
            }
            """
        let result = discover(in: source, sourcePath: "AppConfig.swift")
        #expect(result.unannotatedExtensionProvides.count == 1)
        let candidate = result.unannotatedExtensionProvides[0]
        #expect(candidate.extendedType == "AppConfig")
        #expect(candidate.providerName == "logLevel")
    }

    @Test func strayInjectOnNonScopeAnnotatedTypePropertyEmitsWarning() {
        // `Plain` isn't @Singleton/@RequestScope/@JobScope, so the
        // @Inject on a stored property is a silent no-op without the
        // warning. Surfacing it lets the user understand they need a
        // scope macro to get wiring.
        let source = """
            struct Plain {
                @Inject var logger: Logger
            }
            """
        let result = discover(in: source, sourcePath: "Plain.swift")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@Inject on 'logger' has no effect"))
        #expect(result.warnings[0].message.contains("'Plain'"))
    }

    @Test func strayInjectOnNonScopeAnnotatedTypeInitEmitsWarning() {
        // Same idea, init form. The user might think @Inject on the
        // init marks it as canonical, but without a scope macro on
        // the type there's no macro to read the marker.
        let source = """
            struct Plain {
                @Inject init(x: X) {
                }
            }
            """
        let result = discover(in: source, sourcePath: "Plain.swift")
        #expect(result.warnings.count == 1)
        #expect(
            result.warnings[0].message.contains(
                "@Inject on this initialiser has no effect"
            )
        )
    }

    @Test func injectOnSingletonTypeMemberDoesNotEmitWarning() {
        // Negative case — @Inject on a @Singleton's property IS
        // meaningful (read by the macro for init synthesis). No
        // warning. Pin the contract so a regression that over-warns
        // gets caught.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject var logger: Logger
            }
            """
        let result = discover(in: source, sourcePath: "UserRepo.swift")
        #expect(result.warnings.isEmpty)
    }

    @Test func strayInjectAtModuleScopeEmitsWarning() {
        // `@Inject let foo: Foo` at file scope is a no-op — there's
        // no enclosing type for the macro to read it from. Suggest
        // @Provides as the likely intent.
        let source = """
            @Inject let logger: Logger = Logger()
            """
        let result = discover(in: source, sourcePath: "Logger.swift")
        #expect(result.warnings.count == 1)
        #expect(
            result.warnings[0].message.contains(
                "@Inject on 'logger' at module scope has no effect"
            )
        )
        #expect(result.warnings[0].message.contains("Use @Provides"))
    }

    @Test func injectOnProvidesFuncParameterDoesNotEmitWarning() {
        // `@Provides func make(@Inject(Key) x: X) -> T` uses
        // per-parameter @Inject for keyed disambiguation — meaningful,
        // not stray. The parameter @Inject is inside a func decl,
        // not a top-level var, so the module-scope check doesn't
        // fire either.
        let source = """
            @Provides
            func makeRepo(@Inject(.primary) db: Database) -> Repository {
                Repository(db: db)
            }
            """
        let result = discover(in: source, sourcePath: "Repos.swift")
        #expect(result.warnings.isEmpty)
    }

    @Test func containerAnnotatedExtensionProvidesIsNotACandidate() {
        // `@Container extension Foo { @Provides ... }` is the
        // user's explicit opt-in to contribute to Foo's container —
        // no warning. The candidate list stays empty for this case.
        let source = """
            @Container
            extension AppConfig {
                @Provides static let logLevel: String = "info"
            }
            """
        let result = discover(in: source, sourcePath: "AppConfig.swift")
        #expect(result.unannotatedExtensionProvides.isEmpty)
    }
}
