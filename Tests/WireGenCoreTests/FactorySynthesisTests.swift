import Testing

@testable import WireGenCore

/// Increment 2, step 2: factory synthesis — the consumer-driven half. An
/// annotation declaring `.injectsFactoryOnArgument` (`@Middleware`) drives, per
/// consumed `FactoryKey`, the synthesis of one concrete factory from the matching
/// `@Factory(key)` template, its registration as a binding, and the injection of a
/// factory input edge onto each consumer.
@Suite("Factory synthesis")
struct FactorySynthesisTests {
    // MARK: - Fixtures

    private func template(
        key: String = "MyMiddleware.session",
        typeName: String = "SessionMiddleware",
        assisted: [String] = ["Ctx", "Reader", "Sender"],
        constraints: [String: String] = [:],
        depType: String = "SessionStore",
        module: String = testModule
    ) -> DiscoveredFactoryTemplate {
        DiscoveredFactoryTemplate(
            keyReference: key,
            typeName: typeName,
            qualifiedTypeName: typeName,
            typeKind: "struct",
            genericParameterNames: assisted,
            genericParameterConstraints: constraints,
            dependencies: [
                DependencyParameter(
                    name: "store",
                    type: depType,
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            location: mockLocation("M.swift"),
            originModule: module
        )
    }

    private func middlewareAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "Middleware",
            capability: .injectsFactoryOnArgument,
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
    }

    private func useSite(
        argument: String,
        on target: String = "AccountController"
    ) -> ContributionAliasUseSite {
        ContributionAliasUseSite(
            annotationName: "Middleware",
            targetIdentity: target,
            argument: argument,
            location: mockLocation("C.swift"),
            originModule: testModule
        )
    }

    private func controller(_ name: String = "AccountController") -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("C.swift"),
                originModule: testModule
            )
        )
    }

    private func scopeBound(_ binding: DiscoveredBinding?) -> DiscoveredScopeBoundType? {
        guard case .scopeBound(let type) = binding else { return nil }
        return type
    }

    // MARK: - Synthesis

    @Test func synthesizesOneFactoryPerConsumedKeyDeduped() {
        // Two controllers consume the same key → one factory.
        let factories = synthesizeFactories(
            templates: [template()],
            annotations: [middlewareAnnotation()],
            useSites: [
                useSite(argument: "MyMiddleware.session", on: "AccountController"),
                useSite(argument: "MyMiddleware.session", on: "BillingController"),
            ]
        )
        #expect(factories.count == 1)
        let factory = factories.first
        #expect(factory?.factoryTypeName == "_WireFactory_MyMiddleware_session")
        #expect(factory?.producedTypeName == "SessionMiddleware")
        #expect(factory?.assistedParameterNames == ["Ctx", "Reader", "Sender"])
        #expect(factory?.dependencies.first?.type == "SessionStore")
    }

    @Test func concreteSelfArgumentSynthesizesNoFactory() {
        // `@Middleware(Concrete.self)` is the concrete case, not a template key.
        let factories = synthesizeFactories(
            templates: [template()],
            annotations: [middlewareAnnotation()],
            useSites: [useSite(argument: "ConcreteMiddleware.self")]
        )
        #expect(factories.isEmpty)
    }

    @Test func keyWithoutMatchingTemplateSynthesizesNoFactory() {
        let factories = synthesizeFactories(
            templates: [template(key: "MyMiddleware.session")],
            annotations: [middlewareAnnotation()],
            useSites: [useSite(argument: "Other.unknown")]
        )
        #expect(factories.isEmpty)
    }

    @Test func nonFactoryCapabilityIsIgnored() {
        // A `.contributes`-only annotation of the same name doesn't drive synthesis.
        let contributes = DiscoveredAdapterAnnotation(
            annotationName: "Middleware",
            capability: .contributes(key: "Keys.mw"),
            location: mockLocation("A.swift"),
            originModule: testModule
        )
        let factories = synthesizeFactories(
            templates: [template()],
            annotations: [contributes],
            useSites: [useSite(argument: "MyMiddleware.session")]
        )
        #expect(factories.isEmpty)
    }

    // MARK: - Application: consumer edge + binding registration

    @Test func appendsFactoryEdgeAndRegistersBinding() throws {
        let result = applyFactorySynthesis(
            to: [.default: [controller()]],
            templates: [template()],
            annotations: [middlewareAnnotation()],
            useSites: [useSite(argument: "MyMiddleware.session")],
            consumerModule: testModule
        )
        #expect(result.factories.count == 1)

        let bindings = try #require(result.bindings[.default])
        // The controller gained an input edge on the synthesised factory.
        let controllerType = try #require(
            bindings.compactMap(scopeBound).first { $0.typeName == "AccountController" }
        )
        let edge = try #require(
            controllerType.dependencies.first { $0.type == "_WireFactory_MyMiddleware_session" }
        )
        #expect(edge.name == "_wireFactory_MyMiddleware_session")

        // The factory binding is registered, carrying the template's deps.
        let factoryBinding = try #require(
            bindings.compactMap(scopeBound).first { $0.typeName == "_WireFactory_MyMiddleware_session" }
        )
        #expect(factoryBinding.dependencies.contains { $0.type == "SessionStore" })
    }

    @Test func registersFactoryBindingOncePerPartitionDespiteMultipleConsumers() throws {
        let result = applyFactorySynthesis(
            to: [.default: [controller("AccountController"), controller("BillingController")]],
            templates: [template()],
            annotations: [middlewareAnnotation()],
            useSites: [
                useSite(argument: "MyMiddleware.session", on: "AccountController"),
                useSite(argument: "MyMiddleware.session", on: "BillingController"),
            ],
            consumerModule: testModule
        )
        let bindings = try #require(result.bindings[.default])
        let factoryBindings = bindings.compactMap(scopeBound).filter {
            $0.typeName == "_WireFactory_MyMiddleware_session"
        }
        #expect(factoryBindings.count == 1)
    }

    @Test func noConsumersLeavesBindingsUnchanged() {
        let result = applyFactorySynthesis(
            to: [.default: [controller()]],
            templates: [template()],
            annotations: [middlewareAnnotation()],
            useSites: [],
            consumerModule: testModule
        )
        #expect(result.factories.isEmpty)
        #expect(result.bindings[.default]?.count == 1)
    }

    // MARK: - Rendering

    @Test func rendersFactoryDeclarationWithAssistedCreateAndConstraint() {
        let factory = SynthesizedFactory(
            keyReference: "MyMiddleware.session",
            factoryTypeName: "_WireFactory_MyMiddleware_session",
            producedTypeName: "SessionMiddleware",
            assistedParameterNames: ["Ctx", "Reader", "Sender"],
            assistedParameterConstraints: ["Ctx": "RequestContext"],
            dependencies: [
                DependencyParameter(
                    name: "store",
                    type: "SessionStore",
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            producedTypeModule: testModule,
            location: mockLocation("M.swift")
        )
        let expected = """
            struct _WireFactory_MyMiddleware_session {
                let store: SessionStore
                func create<Ctx, Reader, Sender>(_: Ctx.Type, _: Reader.Type, _: Sender.Type) -> SessionMiddleware<Ctx, Reader, Sender> where Ctx: RequestContext {
                    SessionMiddleware(store: store)
                }
            }
            """
        #expect(renderFactoryDeclaration(factory) == expected)
    }

    @Test func rendersTemplateWhereClauseAfterParameterConstraints() {
        // Associated-type / ~Copyable requirements can't be per-parameter inheritance, so they're
        // restated on `create` after the per-parameter constraints — without them a constrained
        // middleware won't construct.
        let factory = SynthesizedFactory(
            keyReference: "Keys.mw",
            factoryTypeName: "_WireFactory_Keys_mw",
            producedTypeName: "Mw",
            assistedParameterNames: ["Ctx", "Reader"],
            assistedParameterConstraints: ["Ctx": "RequestContext & ~Copyable"],
            whereClause: "Reader.ReadElement == UInt8, Reader: ~Copyable",
            dependencies: [
                DependencyParameter(
                    name: "store",
                    type: "Store",
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            producedTypeModule: testModule,
            location: mockLocation("M.swift")
        )
        #expect(
            renderFactoryDeclaration(factory).contains(
                "where Ctx: RequestContext & ~Copyable, Reader.ReadElement == UInt8, Reader: ~Copyable"
            )
        )
    }

    // MARK: - End-to-end through discovery

    @Test func synthesisFromDiscoveredSource() throws {
        let source = """
            enum WireMVCAdapter {
                static let middleware = WireAdapterAnnotationV1(
                    annotation: "Middleware", capability: .injectsFactoryOnArgument)
            }

            @Factory(MyMiddleware.session)
            struct SessionMiddleware<Ctx, Reader, Sender> {
                @Inject var store: SessionStore
            }

            @Singleton
            @Middleware(MyMiddleware.session)
            struct AccountController {}
            """
        let discovery = discover(in: source, sourcePath: "App.swift", module: testModule)
        let result = applyFactorySynthesis(
            to: discovery.allBindings,
            templates: discovery.factoryTemplates,
            annotations: discovery.adapterAnnotations,
            useSites: discovery.aliasUseSites,
            consumerModule: testModule
        )

        #expect(result.factories.first?.factoryTypeName == "_WireFactory_MyMiddleware_session")
        let bindings = try #require(result.bindings[.default])
        let controller = try #require(
            bindings.compactMap { binding -> DiscoveredScopeBoundType? in
                guard case .scopeBound(let type) = binding, type.typeName == "AccountController" else { return nil }
                return type
            }.first
        )
        #expect(controller.dependencies.contains { $0.type == "_WireFactory_MyMiddleware_session" })
        #expect(
            bindings.contains { $0.aliasTargetIdentity == "_WireFactory_MyMiddleware_session" }
        )
    }
}
