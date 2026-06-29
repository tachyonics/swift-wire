import Testing

@testable import WireGenCore

/// Iteration 8b: adapter-annotation use-sites. These pin that adapter-shaped
/// attributes (`@Name(SomeType.self, ...)`) on type declarations are captured
/// name-agnostically with their annotation name, annotated type (simple and
/// qualified), and type arguments — and that argument-less / labelled
/// attributes (Wire's own macros) are not captured.
@Suite("Adapter use-site discovery")
struct AdapterUseSiteDiscoveryTests {
    private func useSites(in source: String) -> [AdapterUseSite] {
        discover(in: source, sourcePath: "Uses.swift", module: testModule).adapterUseSites
    }

    @Test func capturesGenericArgumentUseSite() throws {
        let source = """
            @RoutedBy(Router<BasicRequestContext>.self)
            struct TaskController {}
            """
        #expect(useSites(in: source).count == 1)
        let site = try #require(useSites(in: source).first)
        #expect(site.annotationName == "RoutedBy")
        #expect(site.annotatedTypeName == "TaskController")
        #expect(site.annotatedQualifiedTypeName == "TaskController")
        #expect(site.typeArguments == ["Router<BasicRequestContext>"])
        #expect(site.originModule == testModule)
    }

    @Test func capturesConcreteArgument() throws {
        let source = """
            @RoutedBy(SimpleRouter.self)
            struct C {}
            """
        let site = try #require(useSites(in: source).first)
        #expect(site.typeArguments == ["SimpleRouter"])
    }

    @Test func capturesMultipleTypeArguments() throws {
        let source = """
            @Wired(A.self, B.self)
            final class C {}
            """
        let site = try #require(useSites(in: source).first)
        #expect(site.annotationName == "Wired")
        #expect(site.typeArguments == ["A", "B"])
    }

    @Test func qualifiedNameIncludesEnclosingType() throws {
        let source = """
            enum Outer {
                @RoutedBy(R.self)
                struct Inner {}
            }
            """
        let site = try #require(useSites(in: source).first)
        #expect(site.annotatedTypeName == "Inner")
        #expect(site.annotatedQualifiedTypeName == "Outer.Inner")
    }

    @Test func captureIsNameAgnostic() throws {
        // Any adapter-shaped attribute is captured as a candidate even with no
        // matching definition — classification happens later (resolution).
        let source = """
            @Whatever(Foo.self)
            struct C {}
            """
        #expect(useSites(in: source).first?.annotationName == "Whatever")
    }

    @Test func ignoresArglessAndLabelledAttributes() {
        // `@Singleton` is arg-less; `@Scoped(seed:)` is labelled — neither is
        // the adapter `@X(T.self)` shape, so neither is captured.
        let source = """
            @Singleton
            @Scoped(seed: RequestSeed.self)
            struct C {}
            """
        #expect(useSites(in: source).isEmpty)
    }

    @Test func unannotatedTypeHasNoUseSites() {
        #expect(useSites(in: "struct Plain {}").isEmpty)
    }
}
