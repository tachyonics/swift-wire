import Testing

@testable import WireGenCore

/// Step 5b: discovery of `@resultBuilder` types and their fold result
/// type, which a `BuilderKey` aggregate produces. The result type comes
/// from `buildFinalResult` when present, else `buildBlock`.
@Suite("Result builder discovery")
struct ResultBuilderDiscoveryTests {
    private func builders(in source: String) -> [DiscoveredResultBuilder] {
        discover(in: source, sourcePath: "B.swift", module: testModule).resultBuilders
    }

    @Test func buildBlockResultTypeIsCaptured() throws {
        let source = """
            @resultBuilder
            enum MiddlewarePipeline {
                static func buildBlock(_ parts: any Middleware...) -> Pipeline {
                    Pipeline(steps: parts.map(\\.step))
                }
            }
            """
        let builder = try #require(builders(in: source).first)
        #expect(builder.typeName == "MiddlewarePipeline")
        #expect(builder.resultType == "Pipeline")
    }

    @Test func buildFinalResultIsPreferredOverBuildBlock() throws {
        let source = """
            @resultBuilder
            struct ChainBuilder {
                static func buildBlock(_ parts: Part...) -> [Part] { parts }
                static func buildFinalResult(_ parts: [Part]) -> Chain { Chain(parts) }
            }
            """
        let builder = try #require(builders(in: source).first)
        #expect(builder.resultType == "Chain")
    }

    @Test func nonResultBuilderTypeIsIgnored() {
        let source = """
            enum NotABuilder {
                static func buildBlock(_ parts: Part...) -> [Part] { parts }
            }
            """
        #expect(builders(in: source).isEmpty)
    }
}
