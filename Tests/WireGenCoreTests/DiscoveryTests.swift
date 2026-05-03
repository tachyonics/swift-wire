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
}
