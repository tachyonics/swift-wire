import Testing

@testable import WireGenCore

/// Increment 2: factory templates — the producer side of the `@Factory(key)` /
/// `@Middleware(key)` factory model. Discovery captures each `@Factory` type as
/// a `DiscoveredFactoryTemplate` (its key, assisted generic parameters, and
/// injected `@Inject` dependencies), and does *not* record it as a graph
/// binding — synthesis is a later, consumer-driven pass.
@Suite("Factory template discovery")
struct FactoryTemplateTests {
    @Test func discoversTemplateWithKeyAssistedParamsAndDeps() throws {
        let source = """
            @Factory(MyMiddleware.session)
            struct SessionMiddleware<Ctx, Reader, Sender> {
                @Inject var store: SessionStore
            }
            """
        let template = try #require(
            discover(in: source, sourcePath: "M.swift", module: testModule).factoryTemplates.first
        )
        #expect(template.keyReference == "MyMiddleware.session")
        #expect(template.typeName == "SessionMiddleware")
        #expect(template.typeKind == "struct")
        #expect(template.genericParameterNames == ["Ctx", "Reader", "Sender"])
        #expect(template.dependencies.count == 1)
        #expect(template.dependencies.first?.type == "SessionStore")
    }

    @Test func capturesWhereClause() throws {
        let source = """
            @Factory(Keys.mw)
            struct Mw<Ctx, Reader> where Reader.ReadElement == UInt8, Reader: ~Copyable {
                @Inject var store: Store
            }
            """
        let template = try #require(
            discover(in: source, sourcePath: "M.swift", module: testModule).factoryTemplates.first
        )
        #expect(template.genericWhereClause == "Reader.ReadElement == UInt8, Reader: ~Copyable")
    }

    @Test func capturesAssistedParameterConstraints() throws {
        let source = """
            @Factory(Keys.authed)
            struct AuthMiddleware<Ctx: RequestContext, Reader, Sender> {
                @Inject var verifier: TokenVerifier
            }
            """
        let template = try #require(
            discover(in: source, sourcePath: "A.swift", module: testModule).factoryTemplates.first
        )
        #expect(template.genericParameterConstraints["Ctx"] == "RequestContext")
        #expect(template.genericParameterConstraints["Reader"] == nil)
    }

    @Test func templateIsNotRecordedAsBinding() {
        // A @Factory template is disjoint from @Singleton — it is not a graph
        // binding of its own; the plugin synthesises factories on demand.
        let source = """
            @Factory(MyMiddleware.session)
            struct SessionMiddleware<Ctx> {
                @Inject var store: SessionStore
            }
            """
        let result = discover(in: source, sourcePath: "M.swift", module: testModule)
        #expect(result.bindings.isEmpty)
        #expect(result.factoryTemplates.count == 1)
    }

    @Test func nonFactoryTypeYieldsNoTemplate() {
        let source = """
            @Singleton
            struct Plain {}
            """
        #expect(discover(in: source, sourcePath: "P.swift", module: testModule).factoryTemplates.isEmpty)
    }
}
