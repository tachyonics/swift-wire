import Testing

@testable import WireGenCore

/// The dead-factory warning (task 20): an `internal` `@Factory` template whose key no use-site
/// references is dead and warns. `package`/`public` stay silent (a cross-module consumer may exist);
/// a template owned by another module (re-parsed during composition) is skipped. Consumption is
/// name-agnostic — any use-site whose argument is the key counts.
@Suite("Dead factory diagnostics")
struct DeadFactoryDiagnosticsTests {
    private func template(
        _ typeName: String = "RequireAPIKey",
        key: String = "Keys.factory",
        access: AccessLevel = .internal,
        module: String = testModule
    ) -> DiscoveredFactoryTemplate {
        DiscoveredFactoryTemplate(
            keyReference: key,
            typeName: typeName,
            qualifiedTypeName: typeName,
            typeKind: "struct",
            genericParameterNames: ["Ctx"],
            dependencies: [],
            accessLevel: access,
            location: mockLocation("\(typeName).swift"),
            originModule: module
        )
    }

    private func useSite(argument: String, on target: String = "SomeController") -> ContributionAliasUseSite {
        ContributionAliasUseSite(
            annotationName: "Middleware",
            targetIdentity: target,
            argument: argument,
            location: mockLocation("C.swift"),
            originModule: testModule
        )
    }

    @Test func internalTemplateWithNoConsumerWarns() {
        let diagnostics = deadFactoryDiagnostics(templates: [template()], useSites: [], owningModule: testModule)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.message.contains("@Factory 'RequireAPIKey' (key Keys.factory)") == true)
    }

    @Test func consumedInternalTemplateIsSilent() {
        let diagnostics = deadFactoryDiagnostics(
            templates: [template()],
            useSites: [useSite(argument: "Keys.factory")],
            owningModule: testModule
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func publicAndPackageTemplatesAreSilent() {
        let diagnostics = deadFactoryDiagnostics(
            templates: [
                template("Pub", key: "Keys.pub", access: .public), template("Pkg", key: "Keys.pkg", access: .package),
            ],
            useSites: [],
            owningModule: testModule
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func templateOwnedByAnotherModuleIsSkipped() {
        // A dependency's internal template re-parsed during composition — that module's own concern.
        let diagnostics = deadFactoryDiagnostics(
            templates: [template(module: "OtherModule")],
            useSites: [],
            owningModule: testModule
        )
        #expect(diagnostics.isEmpty)
    }

    @Test func aSelfArgumentUseSiteDoesNotCountAsConsuming() {
        // The concrete `Type.self` case references an existing binding, not a factory key.
        let diagnostics = deadFactoryDiagnostics(
            templates: [template()],
            useSites: [useSite(argument: "SomeMiddleware.self")],
            owningModule: testModule
        )
        #expect(diagnostics.count == 1)
    }
}
