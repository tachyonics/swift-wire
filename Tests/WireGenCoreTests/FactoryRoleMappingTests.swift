import Testing

@testable import WireGenCore

/// Increment 3.2 — the `.mapsFactoryRoles` role mapping + role-ordered `create` emission. A bare
/// mapping is positional (param[i] → canonicalRole[i]); a custom list maps by the listed roles. Emission
/// makes `create` generic over the canonical roles in fixed order, substitutes the middleware's
/// parameter names → role names in the return type and constraints, and leaves an unused role a phantom
/// parameter. Fixtures are WireMVC-flavoured examples; the mechanism is domain-free.
@Suite("Factory role mapping")
struct FactoryRoleMappingTests {
    private let roles = ["RequestContext", "Reader", "ResponseSender"]

    // MARK: - Mapping computation

    @Test func bareMappingIsPositional() {
        let mapping = factoryRoleMapping(
            assistedParameters: ["Ctx", "Reader", "Sender"],
            useSiteArguments: [],
            canonicalRoles: roles
        )
        #expect(mapping.parameterRoles == ["Ctx": "RequestContext", "Reader": "Reader", "Sender": "ResponseSender"])
    }

    @Test func customMappingReorders() {
        // `@MiddlewareFactory(.responseSender, .reader, .requestContext)` on `<S, R, C>`.
        let mapping = factoryRoleMapping(
            assistedParameters: ["S", "R", "C"],
            useSiteArguments: [".responseSender", ".reader", ".requestContext"],
            canonicalRoles: roles
        )
        #expect(mapping.parameterRoles == ["S": "ResponseSender", "R": "Reader", "C": "RequestContext"])
    }

    @Test func customMappingSubsets() {
        // `@MiddlewareFactory(.requestContext, .responseSender)` on `<C, S>` — reader unused.
        let mapping = factoryRoleMapping(
            assistedParameters: ["C", "S"],
            useSiteArguments: [".requestContext", ".responseSender"],
            canonicalRoles: roles
        )
        #expect(mapping.parameterRoles == ["C": "RequestContext", "S": "ResponseSender"])
    }

    @Test func assistedParametersExcludeInjected() {
        // A concrete-dep template (3.2): every generic parameter is assisted.
        let concrete = template(params: ["Ctx", "Reader", "Sender"], depType: "APIKeyStore")
        #expect(assistedParameters(of: concrete) == ["Ctx", "Reader", "Sender"])
        // A generic-dep template (3.3 shape): the injected parameter drops out.
        let injected = template(params: ["Ctx", "Repository"], depType: "Repository")
        #expect(assistedParameters(of: injected) == ["Ctx"])
    }

    @Test func joinsMappingToTemplateByTypeIdentity() {
        let mappings = factoryRoleMappings(
            templates: [template(params: ["Ctx", "Reader", "Sender"])],
            annotations: [middlewareFactoryAnnotation()],
            useSites: [useSite(on: "RequireAPIKey")]
        )
        #expect(mappings["Keys.factory"]?.canonicalRoles == roles)
        #expect(mappings["Keys.factory"]?.parameterRoles["Sender"] == "ResponseSender")
    }

    // MARK: - Validation

    @Test func validatesEveryAssistedParameterHasARole() {
        // Custom list too short: `<Ctx, Reader, Sender>` given only two roles → Sender unmapped.
        let diagnostics = factoryRoleMappingDiagnostics(
            templates: [template(params: ["Ctx", "Reader", "Sender"])],
            annotations: [middlewareFactoryAnnotation()],
            useSites: [useSite(on: "RequireAPIKey", arguments: [".requestContext", ".reader"])],
            owningModule: testModule
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
        #expect(diagnostics.first?.message.contains("'Sender' has no role") == true)
    }

    @Test func unrecognisedRoleReferenceIsAnError() {
        let diagnostics = factoryRoleMappingDiagnostics(
            templates: [template(params: ["Ctx"])],
            annotations: [middlewareFactoryAnnotation()],
            useSites: [useSite(on: "RequireAPIKey", arguments: [".notARole"])],
            owningModule: testModule
        )
        #expect(diagnostics.contains { $0.message.contains("'Ctx' has no role") })
    }

    @Test func validMappingHasNoDiagnostics() {
        let diagnostics = factoryRoleMappingDiagnostics(
            templates: [template(params: ["Ctx", "Reader", "Sender"])],
            annotations: [middlewareFactoryAnnotation()],
            useSites: [useSite(on: "RequireAPIKey")],  // bare → positional, all mapped
            owningModule: testModule
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func templateWithoutMappingIsNotValidated() {
        // No `.mapsFactoryRoles` annotation visible → positional fallback, no validation.
        let diagnostics = factoryRoleMappingDiagnostics(
            templates: [template(params: ["Ctx", "Reader", "Sender"])],
            annotations: [],
            useSites: [],
            owningModule: testModule
        )
        #expect(diagnostics.isEmpty)
    }

    // MARK: - Emission

    @Test func rendersCanonicalRoleOrderedCreate() {
        let rendered = renderFactoryDeclaration(
            factory(
                params: ["Ctx", "Reader", "Sender"],
                constraints: [
                    "Ctx": "HTTPServerCapability.RequestContext & ~Copyable",
                    "Reader": "AsyncReader & ~Copyable", "Sender": "HTTPResponseSender & ~Copyable",
                ],
                whereClause: "Reader.ReadElement == UInt8, Sender.Writer: ~Copyable",
                parameterRoles: ["Ctx": "RequestContext", "Reader": "Reader", "Sender": "ResponseSender"]
            )
        )
        #expect(
            rendered.contains(
                "func create<RequestContext, Reader, ResponseSender>(_: RequestContext.Type, _: Reader.Type, _: ResponseSender.Type) -> RequireAPIKey<RequestContext, Reader, ResponseSender>"
            )
        )
        // The `Sender` parameter was substituted → `ResponseSender` in the where clause.
        #expect(rendered.contains("ResponseSender.Writer: ~Copyable"))
        #expect(rendered.contains("ResponseSender: HTTPResponseSender & ~Copyable"))
    }

    @Test func rendersReorderedCreate() {
        let rendered = renderFactoryDeclaration(
            factory(
                producedType: "Reordered",
                params: ["S", "R", "C"],
                constraints: [
                    "S": "HTTPResponseSender & ~Copyable", "R": "AsyncReader & ~Copyable",
                    "C": "HTTPServerCapability.RequestContext & ~Copyable",
                ],
                whereClause: "R.ReadElement == UInt8, S.Writer: ~Copyable",
                parameterRoles: ["S": "ResponseSender", "R": "Reader", "C": "RequestContext"]
            )
        )
        #expect(
            rendered.contains(
                "func create<RequestContext, Reader, ResponseSender>(_: RequestContext.Type, _: Reader.Type, _: ResponseSender.Type) -> Reordered<ResponseSender, Reader, RequestContext>"
            )
        )
        #expect(rendered.contains("ResponseSender: HTTPResponseSender & ~Copyable"))
        #expect(rendered.contains("RequestContext: HTTPServerCapability.RequestContext & ~Copyable"))
    }

    @Test func rendersSubsetCreateWithPhantomRole() {
        let rendered = renderFactoryDeclaration(
            factory(
                producedType: "PinnedReader",
                params: ["C", "S"],
                constraints: [
                    "C": "HTTPServerCapability.RequestContext & ~Copyable",
                    "S": "HTTPResponseSender & ~Copyable",
                ],
                whereClause: "S.Writer: ~Copyable",
                parameterRoles: ["C": "RequestContext", "S": "ResponseSender"]  // Reader unused
            )
        )
        // Reader is a phantom generic + metatype parameter, absent from the return.
        #expect(
            rendered.contains(
                "func create<RequestContext, Reader, ResponseSender>(_: RequestContext.Type, _: Reader.Type, _: ResponseSender.Type) -> PinnedReader<RequestContext, ResponseSender>"
            )
        )
        // No constraint mentions Reader (it's unused/phantom) — it appears only as the metatype
        // parameter `_: Reader.Type` and the generic `<…, Reader, …>`, never `Reader:` or in the return.
        #expect(rendered.contains("Reader:") == false)
        #expect(rendered.contains("PinnedReader<RequestContext, ResponseSender>"))
    }

    // MARK: - Fixtures

    private func template(
        params: [String] = ["Ctx", "Reader", "Sender"],
        depType: String = "APIKeyStore"
    ) -> DiscoveredFactoryTemplate {
        DiscoveredFactoryTemplate(
            keyReference: "Keys.factory",
            typeName: "RequireAPIKey",
            qualifiedTypeName: "RequireAPIKey",
            typeKind: "struct",
            genericParameterNames: params,
            dependencies: [
                DependencyParameter(
                    name: "keys",
                    type: depType,
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            location: mockLocation("M.swift"),
            originModule: testModule
        )
    }

    private func middlewareFactoryAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "MiddlewareFactory",
            capability: .mapsFactoryRoles(roles: roles),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
    }

    private func useSite(on target: String, arguments: [String] = []) -> ContributionAliasUseSite {
        ContributionAliasUseSite(
            annotationName: "MiddlewareFactory",
            targetIdentity: target,
            argument: arguments.first,
            arguments: arguments,
            location: mockLocation("M.swift"),
            originModule: testModule
        )
    }

    private func factory(
        producedType: String = "RequireAPIKey",
        params: [String],
        constraints: [String: String],
        whereClause: String?,
        parameterRoles: [String: String]
    ) -> SynthesizedFactory {
        SynthesizedFactory(
            keyReference: "Keys.factory",
            factoryTypeName: "_WireFactory_Keys_factory",
            producedTypeName: producedType,
            assistedParameterNames: params,
            assistedParameterConstraints: constraints,
            whereClause: whereClause,
            dependencies: [
                DependencyParameter(
                    name: "keys",
                    type: "APIKeyStore",
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            producedTypeModule: testModule,
            location: mockLocation("M.swift"),
            roleMapping: FactoryRoleMapping(canonicalRoles: roles, parameterRoles: parameterRoles)
        )
    }
}
