import Testing

@testable import WireGenCore

/// Phase A, A1 — the structural half of a plugin-generated contributor proxy. `renderContributorProxyDeclaration`
/// emits the proxy `struct` (fields + init + `Sendable`, generic exactly as the subject) with a *body hole*:
/// no adapter-protocol conformance, no witness method — those arrive in a domain tool's `extension`. These
/// tests pin the emitted struct's shape and the field-name contract (`_wireSubject` / `_wireFactory_<key>`)
/// the domain body generator meets it on. Fixtures are WireMVC-flavoured (`Controller` / factory) as concrete
/// examples; the emitter itself is domain-free.
@Suite("Contributor-proxy structural emission")
struct ContributorProxyEmissionTests {

    /// Build a proxy binding the way the pre-graph passes do — the contributor-proxy synthesis makes the
    /// bare proxy (subject as the positional, unlabelled first dependency), then factory synthesis appends
    /// the lifted factories as labelled dependencies. This helper composes both so the fixture matches the
    /// binding `renderContributorProxyDeclaration` receives in the pipeline.
    private func proxyBinding(
        typeName: String = "_WireRouteContributor_TodosController",
        params: [String] = ["Repository"],
        constraints: [String: String] = ["Repository": "TodoRepository"],
        whereClause: String? = nil,
        subjectType: String = "TodosController<Repository>",
        access: AccessLevel = .public,
        factoryKeys: [String] = []
    ) -> DiscoveredScopeBoundType {
        var dependencies: [DependencyParameter] = [
            DependencyParameter(
                name: nil,  // the subject — positional/unlabelled
                type: subjectType,
                kind: .injectInitParameter,
                location: mockLocation("C.swift")
            )
        ]
        for key in factoryKeys {
            dependencies.append(
                DependencyParameter(
                    name: factoryDependencyName(forKey: key),
                    type: factoryTypeName(forKey: key),
                    kind: .injectInitParameter,
                    location: mockLocation("M.swift")
                )
            )
        }
        return DiscoveredScopeBoundType(
            typeName: typeName,
            typeKind: "struct",
            genericParameterNames: params,
            genericParameterConstraints: constraints,
            genericWhereClause: whereClause,
            dependencies: dependencies,
            location: mockLocation("C.swift"),
            accessLevel: access,
            originModule: testModule
        )
    }

    // MARK: - Struct shape

    @Test func emitsGenericStructWithSubjectFieldAndInit() {
        let declaration = renderContributorProxyDeclaration(proxyBinding())
        let expected = """
            public struct _WireRouteContributor_TodosController<Repository: TodoRepository>: Sendable {
                public let _wireSubject: TodosController<Repository>
                public init(_ _wireSubject: TodosController<Repository>) {
                    self._wireSubject = _wireSubject
                }
            }
            """
        #expect(declaration == expected)
    }

    @Test func emitsFactoryFieldsAfterSubject() {
        let declaration = renderContributorProxyDeclaration(
            proxyBinding(factoryKeys: ["Keys.backend"])
        )
        let expected = """
            public struct _WireRouteContributor_TodosController<Repository: TodoRepository>: Sendable {
                public let _wireSubject: TodosController<Repository>
                public let _wireFactory_Keys_backend: _WireFactory_Keys_backend
                public init(_ _wireSubject: TodosController<Repository>, _wireFactory_Keys_backend: _WireFactory_Keys_backend) {
                    self._wireSubject = _wireSubject
                    self._wireFactory_Keys_backend = _wireFactory_Keys_backend
                }
            }
            """
        #expect(declaration == expected)
    }

    @Test func nonGenericProxyOmitsGenericClause() {
        let declaration = renderContributorProxyDeclaration(
            proxyBinding(
                typeName: "_WireRouteContributor_HealthController",
                params: [],
                constraints: [:],
                subjectType: "HealthController"
            )
        )
        let expected = """
            public struct _WireRouteContributor_HealthController: Sendable {
                public let _wireSubject: HealthController
                public init(_ _wireSubject: HealthController) {
                    self._wireSubject = _wireSubject
                }
            }
            """
        #expect(declaration == expected)
    }

    // MARK: - Field-name contract (the structural ↔ domain handshake)

    @Test func subjectFieldNameIsTheDocumentedContract() {
        #expect(contributorProxySubjectFieldName == "_wireSubject")
    }

    @Test func factoryFieldNameMatchesFactoryDependencyName() {
        // The proxy's factory field must be named exactly as the graph's construction call labels it and
        // as the factory synthesis names the lifted dependency — `_wireFactory_<sanitized key>`.
        let declaration = renderContributorProxyDeclaration(proxyBinding(factoryKeys: ["Keys.backend"]))
        #expect(declaration.contains("let \(factoryDependencyName(forKey: "Keys.backend")):"))
        #expect(declaration.contains("_wireFactory_Keys_backend"))
    }

    @Test func multipleFactoriesEmitInDependencyOrder() {
        let declaration = renderContributorProxyDeclaration(
            proxyBinding(factoryKeys: ["Keys.auth", "Keys.rateLimit"])
        )
        let fieldLines = declaration.split(separator: "\n").map(String.init)
        let authLine = fieldLines.firstIndex { $0.contains("let _wireFactory_Keys_auth:") }
        let rateLine = fieldLines.firstIndex { $0.contains("let _wireFactory_Keys_rateLimit:") }
        #expect(authLine != nil && rateLine != nil)
        #expect(authLine! < rateLine!)
    }

    // MARK: - Body hole

    @Test func emitsNoWitnessNorAdapterConformance() {
        let declaration = renderContributorProxyDeclaration(proxyBinding(factoryKeys: ["Keys.backend"]))
        // Structural only — the domain half (conformance + witness) is a separate tool's extension.
        // (The proxy *type name* contains "RouteContributor"; what must be absent is a conformance to a
        // domain protocol and any method.) The sole inheritance is `Sendable`.
        #expect(!declaration.contains(": RouteContributor"))
        #expect(!declaration.contains(", RouteContributor"))
        #expect(!declaration.contains("func "))
        #expect(!declaration.contains("registerWireRoutes"))
        // Sendable stays on the struct (structural — every graph binding is Sendable in Wire's model).
        #expect(declaration.contains(": Sendable {"))
    }

    // MARK: - Access level

    @Test func packageSubjectEmitsPackageProxy() {
        let declaration = renderContributorProxyDeclaration(proxyBinding(access: .package))
        #expect(declaration.hasPrefix("package struct "))
        #expect(declaration.contains("package let _wireSubject:"))
        #expect(declaration.contains("package init("))
    }

    @Test func internalSubjectEmitsNoAccessKeyword() {
        let declaration = renderContributorProxyDeclaration(proxyBinding(access: .internal))
        #expect(declaration.hasPrefix("struct "))
        #expect(declaration.contains("\n    let _wireSubject:"))
        #expect(declaration.contains("\n    init("))
    }

    // MARK: - Where clause

    // MARK: - The handshake, end to end

    /// The emitted struct's initialiser and the graph's construction call are the two sides of the
    /// field-name handshake — they must agree, or the generated module won't compile. This renders both
    /// from the same proxy binding and pins that they line up: the subject is passed *positionally* (the
    /// init's first parameter is unlabelled) and each factory is passed under the `_wireFactory_<key>`
    /// label the init declares. Non-generic subject to keep the graph free of the `T0` lift (an emission
    /// concern this test isn't about). Mirrors spike-23's compiler-checked handshake at the unit level.
    @Test func emittedInitMatchesGraphConstructionCall() {
        let subject = DiscoveredScopeBoundType(
            typeName: "HealthController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [],
            location: mockLocation("H.swift"),
            accessLevel: .public,
            originModule: testModule
        )
        let factory = DiscoveredScopeBoundType(
            typeName: "_WireFactory_Keys_backend",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [],
            location: mockLocation("M.swift"),
            originModule: testModule
        )
        let proxy = proxyBinding(
            typeName: "_WireRouteContributor_HealthController",
            params: [],
            constraints: [:],
            subjectType: "HealthController",
            factoryKeys: ["Keys.backend"]
        )

        // The emitted init accepts the subject positionally and the factory under its `_wireFactory_` label.
        let declaration = renderContributorProxyDeclaration(proxy)
        #expect(
            declaration.contains(
                "init(_ _wireSubject: HealthController, _wireFactory_Keys_backend: _WireFactory_Keys_backend)"
            )
        )

        // The graph's bootstrap constructs the proxy with exactly that shape: `healthController`
        // positionally (no label), the factory under `_wireFactory_Keys_backend:`.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [.scopeBound(subject), .scopeBound(factory), .scopeBound(proxy)],
            syntheticTypeDeclarations: [declaration]
        )
        #expect(
            output.contains(
                "_WireRouteContributor_HealthController(healthController, _wireFactory_Keys_backend: "
            )
        )
    }

    @Test func restatesSubjectWhereClause() {
        let declaration = renderContributorProxyDeclaration(
            proxyBinding(
                params: ["Element"],
                constraints: ["Element": "Sendable"],
                whereClause: "Element: Codable"
            )
        )
        #expect(
            declaration.hasPrefix(
                "public struct _WireRouteContributor_TodosController<Element: Sendable>: Sendable where Element: Codable {"
            )
        )
    }
}
