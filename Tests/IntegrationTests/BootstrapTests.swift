import Testing

@Suite("Bootstrap")
struct BootstrapTests {
    @Test func bootstrapWiresFullDependencyChain() async throws {
        // Greeter → UserRepository → Logger. The end-to-end chain
        // proves the generated `_WireGraph.swift` constructed each
        // binding in dependency order and threaded the right local
        // through each subsequent constructor.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.greeter.greet("alice") == "alice: [log] UserRepository")
    }

    @Test func storedPropertiesAreNamedByLowerCamelCasedTypeName() async throws {
        // Confirms WireGen's naming convention round-trips: the
        // accessor on the generated struct is lowerCamelCased(typeName).
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.logger.log("hello") == "[log] hello")
        #expect(graph.userRepository.describe() == "[log] UserRepository")
    }

    // MARK: - @Provides bindings

    @Test func providersAtAllAttachmentSitesProduceWiredGraph() async throws {
        // Exercises the three @Provides shapes in one chain:
        //   - module-scope @Provides let appName: AppName
        //   - static @Provides let buildNumber: BuildNumber on enum BuildInfo
        //   - module-scope @Provides func makeBanner(appName:, buildNumber:)
        // The two property-form providers are constructed first, then
        // makeBanner is invoked with both as resolved arguments, then
        // BannerService (a @Singleton) injects the produced Banner.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.bannerService.display() == "IntegrationTests #42")
    }

    @Test func providerStoredPropertiesAreAccessibleByBoundType() async throws {
        // Each @Provides binding gets a stored property on _WireGraph
        // named by the bound type — `appName` for AppName, `banner` for
        // Banner — independent of the source-level declaration name.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.appName.value == "IntegrationTests")
        #expect(graph.buildNumber.value == 42)
        #expect(graph.banner.text == "IntegrationTests #42")
    }

    // MARK: - @Container bindings

    @Test func testContainerProducesWiredGraphFromOwnBindings() async throws {
        // Exercises the per-container codegen end-to-end:
        //   - `_TestContainerWireGraph.bootstrap()` resolves
        //   - `@Provides static let banner` (primary declaration)
        //   - nested `@Singleton struct MockBannerService` (also primary)
        //     with `qualifiedTypeName` "TestContainer.MockBannerService"
        //   - `@Provides static let testMode` (from the `@Container
        //     extension`)
        // All bindings come from the container — module-scope @Provides
        // and module-scope @Singletons do not leak in.
        let graph = try await _TestContainerWireGraph.bootstrap()
        #expect(graph.banner.text == "test container")
        #expect(graph.testMode.value == "integration-test")
        #expect(graph.mockBannerService.display() == "mock: test container")
    }

    @Test func defaultGraphAndTestContainerAreIndependent() async throws {
        // Both graphs bind the *same* type (`Banner`), but with
        // different sources: the default graph synthesises it via
        // `makeBanner(appName:, buildNumber:)`, while the container
        // provides a fixed value. Proves the two graphs are atomic
        // and live side-by-side without conflict.
        let defaultGraph = try await _WireGraph.bootstrap()
        let testGraph = try await _TestContainerWireGraph.bootstrap()

        #expect(defaultGraph.banner.text == "IntegrationTests #42")
        #expect(testGraph.banner.text == "test container")
    }

    // MARK: - Explicit-key disambiguation

    @Test func genericSingletonSpecialisedForConcreteConsumer() async throws {
        // `Container<T>` is generic; `GenericConsumer` asks for
        // `Container<DataPoint>`. The build plugin specialises the
        // generic binding with `T = DataPoint`, substitutes the dep
        // `item: T` to `item: DataPoint`, and emits a concrete
        // `Container<DataPoint>` binding the consumer resolves
        // against — confirming sitting 2b's generic-specialisation
        // phase wires through end-to-end (graph specialisation +
        // codegen with the concrete type expression at the call
        // site).
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.genericConsumer.describe() == "Container(DataPoint(value: 42))")
        // The specialised binding is reachable from the graph under
        // the type-derived accessor name.
        #expect(graph.containerOfDataPoint.describe() == "Container(DataPoint(value: 42))")
    }

    // MARK: - Explicit-key disambiguation

    @Test func keyedConsumerInjectsTheMatchingKeyedProvider() async throws {
        // KeyedConsumer has `@Inject(AppName.alternate) var alternate:
        // AppName`. The matching `@Provides(AppName.alternate)` binds a
        // distinct `AppName("alternate")` from the unkeyed module-scope
        // `appName`. Confirms (a) the `(type, key)` graph identity
        // resolves correctly end-to-end, (b) the generated key-checks
        // file accepts the matching pairing without compile failure,
        // and (c) the keyed accessor on `_WireGraph` doesn't collide
        // with the unkeyed `appName`.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.keyedConsumer.describe() == "consumer with alternate")
        // Both unkeyed and keyed AppName bindings are reachable from
        // the graph under distinct property names. The keyed accessor
        // is verbose by design — the `Keyed` infix separates the type-
        // derived prefix from the sanitised key suffix and pushes
        // collisions with unkeyed type names out to "name contains the
        // word `Keyed`," which doesn't happen in real code.
        #expect(graph.appName.value == "IntegrationTests")
        #expect(graph.appNameKeyedAppNameAlternate.value == "alternate")
    }
}
