import Testing

@testable import WireGenCore

@Suite("Discovery")
struct DiscoveryTests {
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

    // MARK: - renderDiscoveryReport

    @Test func discoveryReportHeaderAndCountWithEmptyInput() {
        let report = renderDiscoveryReport(perFile: [])
        #expect(report.contains("WireGen discovery report"))
        #expect(report.contains("discovered 0 @Singleton type(s) across 0 source file(s)"))
    }

    @Test func discoveryReportSkipsFilesWithNoSingletons() {
        // Files that contained no @Singletons should not appear in the
        // report body; they still count toward "source file(s)" though.
        let item = DiscoveredSingleton(
            typeName: "A",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [],
            sourcePath: "Found.swift"
        )
        let report = renderDiscoveryReport(perFile: [
            (path: "Empty.swift", items: []),
            (path: "Found.swift", items: [item]),
        ])
        #expect(!report.contains("Empty.swift"))
        #expect(report.contains("Found.swift"))
        #expect(report.contains("discovered 1 @Singleton type(s) across 2 source file(s)"))
    }

    @Test func discoveryReportRendersGenerics() {
        let item = DiscoveredSingleton(
            typeName: "Repository",
            typeKind: "struct",
            genericParameterNames: ["Model"],
            dependencies: [],
            sourcePath: "R.swift"
        )
        let report = renderDiscoveryReport(perFile: [(path: "R.swift", items: [item])])
        #expect(report.contains("@Singleton struct Repository<Model>"))
    }

    @Test func discoveryReportRendersInjectPropertyDependency() {
        let item = DiscoveredSingleton(
            typeName: "A",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(name: "b", type: "B", kind: .injectProperty)
            ],
            sourcePath: "A.swift"
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("b: B"))
        #expect(report.contains("@Inject property"))
    }

    @Test func discoveryReportRendersInjectInitParameterDependency() {
        let item = DiscoveredSingleton(
            typeName: "A",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(name: "b", type: "B", kind: .injectInitParameter)
            ],
            sourcePath: "A.swift"
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("@Inject init parameter"))
    }

    @Test func discoveryReportShowsNoDependenciesNoticeWhenEmpty() {
        let item = DiscoveredSingleton(
            typeName: "A",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [],
            sourcePath: "A.swift"
        )
        let report = renderDiscoveryReport(perFile: [(path: "A.swift", items: [item])])
        #expect(report.contains("(no dependencies)"))
    }
}
