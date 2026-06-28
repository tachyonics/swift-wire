import Testing

@testable import WireGenCore

/// Iteration 8a: adapter-annotation definitions. These pin that
/// `WireAdapterAnnotationV1` declarations are discovered anywhere in source
/// with their annotation name, form, phase, and register-signature template,
/// and that non-matching declarations are ignored.
@Suite("Adapter annotation discovery")
struct AdapterAnnotationDiscoveryTests {
    private func definitions(in source: String) -> [DiscoveredAdapterAnnotation] {
        discover(in: source, sourcePath: "Adapters.swift", module: testModule).adapterAnnotations
    }

    @Test func staticDefinitionCapturesAllFields() throws {
        let source = """
            enum RoutingAdapter {
                static let routedBy = WireAdapterAnnotationV1(
                    annotation: "RoutedBy",
                    form: .typeLevel,
                    phase: .postGraph,
                    registerSignature: "(instance: Self, router: $0)"
                )
            }
            """
        #expect(definitions(in: source).count == 1)
        let definition = try #require(definitions(in: source).first)
        #expect(definition.annotationName == "RoutedBy")
        #expect(definition.form == .typeLevel)
        #expect(definition.phase == .postGraph)
        #expect(definition.registerSignature == "(instance: Self, router: $0)")
        #expect(definition.originModule == testModule)
    }

    @Test func moduleScopeDefinitionIsDiscovered() throws {
        let source = """
            let routedBy = WireAdapterAnnotationV1(
                annotation: "RoutedBy", form: .typeLevel, phase: .postGraph,
                registerSignature: "(instance: Self)"
            )
            """
        let definition = try #require(definitions(in: source).first)
        #expect(definition.annotationName == "RoutedBy")
        #expect(definition.registerSignature == "(instance: Self)")
    }

    @Test func nonAdapterDeclarationsAreIgnored() {
        let source = """
            enum Keys {
                static let primary = BindingKey<Database>()
                static let count = 3
            }
            """
        #expect(definitions(in: source).isEmpty)
    }

    @Test func unknownEnumCaseIsNotDiscovered() {
        // A form/phase Wire doesn't recognise (a future contract shape) is
        // dropped rather than mis-mapped.
        let source = """
            enum A {
                static let x = WireAdapterAnnotationV1(
                    annotation: "X", form: .perRequest, phase: .postGraph,
                    registerSignature: "(instance: Self)"
                )
            }
            """
        #expect(definitions(in: source).isEmpty)
    }
}
