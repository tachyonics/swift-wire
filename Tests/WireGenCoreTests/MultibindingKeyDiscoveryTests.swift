import Testing

@testable import WireGenCore

/// Step 1 of iteration 5β: the key-declaration scanner. These pin that
/// `CollectedKey`/`MappedKey`/`BuilderKey` declarations are captured with
/// the right flavour, verbatim generic argument(s), canonical reference
/// text, and effective access — and that non-key declarations are left
/// alone. The keys are discovered-but-unused at this step; the fan-in
/// pass (Step 4) consumes them.
@Suite("Multibinding key discovery")
struct MultibindingKeyDiscoveryTests {
    private func keys(in source: String) -> [DiscoveredMultibindingKey] {
        discover(in: source, sourcePath: "Keys.swift").multibindingKeys
    }

    @Test func collectedKeyOnExtensionCapturesFlavourTypeAndReference() throws {
        let source = """
            extension App {
                static let services = CollectedKey<any Service>()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(keys(in: source).count == 1)
        #expect(key.keyReference == "App.services")
        #expect(key.flavour == .collected)
        #expect(key.typeArguments == ["any Service"])
    }

    @Test func mappedKeyCapturesBothTypeArguments() throws {
        let source = """
            enum App {
                static let strategies = MappedKey<String, any Strategy>()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.keyReference == "App.strategies")
        #expect(key.flavour == .mapped)
        #expect(key.typeArguments == ["String", "any Strategy"])
    }

    @Test func builderKeyCapturesBuilderTypeArgument() throws {
        let source = """
            enum App {
                static let middleware = BuilderKey<MiddlewareBuilder>()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.flavour == .builder)
        #expect(key.typeArguments == ["MiddlewareBuilder"])
    }

    @Test func moduleScopeKeyHasUnqualifiedReference() throws {
        let source = "let services = CollectedKey<any Service>()"
        let key = try #require(keys(in: source).first)
        #expect(key.keyReference == "services")
        #expect(key.flavour == .collected)
    }

    @Test func explicitTypeAnnotationFormIsCaptured() throws {
        // Flavour and generics read from the annotation, not the RHS.
        let source = """
            enum App {
                static let services: CollectedKey<any Service> = .init()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.flavour == .collected)
        #expect(key.typeArguments == ["any Service"])
    }

    @Test func keyWithoutExplicitGenericsCapturesEmptyTypeArguments() throws {
        // `= CollectedKey()` with no annotation: flavour is known, but
        // the producer-side type isn't — captured empty for a later
        // step to diagnose.
        let source = """
            enum App {
                static let services = CollectedKey()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.flavour == .collected)
        #expect(key.typeArguments.isEmpty)
    }

    @Test func effectiveAccessFoldsEnclosingTypeAccess() throws {
        // A `public` key inside an `internal` enum is effectively
        // `internal` — the enclosing type clamps it.
        let source = """
            internal enum App {
                public static let services = CollectedKey<any Service>()
            }
            """
        let key = try #require(keys(in: source).first)
        #expect(key.accessLevel == .internal)
    }

    @Test func nonKeyDeclarationsAreIgnored() {
        let source = """
            enum App {
                static let count = 3
                static let key = BindingKey<Service>()
                @Provides static let logger: Logger = Logger()
            }
            """
        #expect(keys(in: source).isEmpty)
    }

    @Test func instanceLevelKeyDeclarationIsIgnored() {
        // A non-static stored property on a type isn't a graph key
        // (mirrors the `@Provides` recognised-position discipline).
        let source = """
            struct App {
                let services = CollectedKey<any Service>()
            }
            """
        #expect(keys(in: source).isEmpty)
    }
}
