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

    // MARK: - Effect-aware emission

    @Test func asyncThrowsProviderFunctionResolvesThroughBootstrap() async throws {
        // `@Provides func makeAsyncToken() async throws -> AsyncToken`
        // exercises effect-aware emission for the function-provider
        // shape end-to-end. The generated bootstrap emits
        // `try await makeAsyncToken()`; if the prefix is missing the
        // file wouldn't compile, if the runtime semantics are wrong
        // the assertion fails.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.asyncToken.value == "async-token-resolved")
        #expect(graph.asyncTokenConsumer.describe() == "consumer holds async-token-resolved")
    }

    @Test func asyncThrowsComputedPropertyResolvesThroughBootstrap() async throws {
        // `@Provides static var asyncMessage: AsyncMessage { get async throws }`
        // exercises the computed-property accessor path. Discovery
        // walks the accessor block and tags the binding; codegen
        // emits `let asyncMessage = try await AsyncFactories.asyncMessage`
        // — the property reference itself is the call site of the
        // effectful getter.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.asyncMessage.payload == "computed-property-resolved")
    }

    @Test func asyncThrowsInjectInitResolvesThroughBootstrap() async throws {
        // User-written `@Inject init(...) async throws` on a
        // `@Singleton` type. Discovery reads the init's effect
        // specifiers; codegen emits
        // `let asyncInitConsumer = try await AsyncInitConsumer(token:, message:)`.
        // The init's body performs real async work (Task.sleep) so
        // the suspension propagates through bootstrap evaluation.
        let graph = try await _WireGraph.bootstrap()
        #expect(
            graph.asyncInitConsumer.describe()
                == "init received async-token-resolved + computed-property-resolved"
        )
    }

    // MARK: - User-written `@Provides -> Lazy<T>`

    @Test func userWrittenLazyProviderDoesNotInvokeFactoryAtBootstrap() async throws {
        // The canonical Wire posture: `Lazy<LazyResource>` is just a
        // binding type, bootstrap allocates the wrapper, the factory
        // closure inside doesn't run until someone calls `.get()`.
        // Counter at zero after bootstrap = factory deferred correctly.
        let graph = try await _WireGraph.bootstrap()
        #expect(await graph.lazyResourceCallCount.value == 0)
    }

    @Test func userWrittenLazyProviderInvokesFactoryOnFirstGet() async throws {
        // First `.get()` runs the factory exactly once; counter goes
        // from zero to one. Pins the "deferred until first use" half
        // of the Lazy semantics.
        let graph = try await _WireGraph.bootstrap()
        let materialised = try await graph.lazyResourceConsumer.materialise()
        #expect(materialised.value == "materialised")
        #expect(await graph.lazyResourceCallCount.value == 1)
    }

    @Test func userWrittenLazyProviderCachesAcrossMultipleGets() async throws {
        // Multiple `.get()` calls return the same instance and never
        // re-invoke the factory. Pins the "cached after first use" half
        // of the Lazy semantics — the first-use-singleton pattern's
        // load-bearing property.
        let graph = try await _WireGraph.bootstrap()
        let consumer = graph.lazyResourceConsumer
        let first = try await consumer.materialise()
        let second = try await consumer.materialise()
        let third = try await consumer.materialise()
        #expect(first === second)
        #expect(second === third)
        #expect(await graph.lazyResourceCallCount.value == 1)
    }

    // MARK: - `@Scoped(seed:)` end-to-end

    @Test func seedScopeBootstrapInjectsSeedAndBorrowsSingleton() async throws {
        // The generated `_TestRequestSeedWireScope.bootstrap(seed:wireGraph:)`
        // takes the seed value and the singletons graph; `RequestLogger`
        // (`@Scoped(seed: TestRequestSeed.self)`) injects both the
        // seed and the singleton `Logger`. The seed lands on the
        // scope struct as a stored property; the singleton is
        // borrowed (inlined at `RequestLogger`'s constructor site,
        // not stored).
        let graph = try await _WireGraph.bootstrap()
        let scope = try await _TestRequestSeedWireScope.bootstrap(
            seed: TestRequestSeed(id: "req-1"),
            wireGraph: graph
        )
        #expect(scope.testRequestSeed.id == "req-1")
        #expect(scope.requestLogger.log("hello") == "[log] [req-1] hello")
    }

    @Test func seedScopeBootstrapResolvesInScopeDependencies() async throws {
        // `RequestHandler` depends on `RequestLogger` — both
        // `@Scoped(seed: TestRequestSeed.self)`. The generated
        // bootstrap must construct `RequestLogger` first and pass it
        // into `RequestHandler`'s init. The handler reads through to
        // the same scope's seed and singleton via the in-scope
        // logger.
        let graph = try await _WireGraph.bootstrap()
        let scope = try await _TestRequestSeedWireScope.bootstrap(
            seed: TestRequestSeed(id: "req-2"),
            wireGraph: graph
        )
        #expect(scope.requestHandler.handle("create") == "[log] [req-2] handling create")
    }

    @Test func containerScopeBootstrapBorrowsFromContainerWireGraph() async throws {
        // `TestContainer.JobRunner` is `@Scoped(seed: TestJobSeed.self)`
        // and lives inside `@Container TestContainer`. The generated
        // `_TestContainer_TestJobSeedWireScope.bootstrap(seed:testContainerWireGraph:)`
        // takes the container's graph (not `_WireGraph`) and borrows
        // its `banner` from there. Exercises the (container, scope)
        // partition cell end-to-end: distinct struct name from any
        // default-graph scope, distinct parent-graph parameter type,
        // borrow path resolves against the container's graph.
        let containerGraph = try await _TestContainerWireGraph.bootstrap()
        let scope = try await _TestContainer_TestJobSeedWireScope.bootstrap(
            seed: TestJobSeed(queue: "high"),
            testContainerWireGraph: containerGraph
        )
        // The seed lands on the scope struct.
        #expect(scope.testJobSeed.queue == "high")
        // The borrow resolves to the *container's* banner, not the
        // default graph's banner. (The container's banner is the
        // fixed string "test container"; the default graph's is
        // composed via `makeBanner(appName:buildNumber:)` and reads
        // "IntegrationTests #42".)
        #expect(scope.jobRunner.run() == "[high] running on test container")
    }

    @Test func seedScopeEntriesProduceDistinctInstances() async throws {
        // Each `bootstrap(seed:wireGraph:)` call constructs a fresh
        // scope. Two entries with distinct seeds yield distinct
        // scope-bound instances and distinct seed-derived behaviour.
        // Singletons are shared (same `graph` passed in both calls),
        // so the underlying logger is the same instance both times.
        let graph = try await _WireGraph.bootstrap()
        let scopeA = try await _TestRequestSeedWireScope.bootstrap(
            seed: TestRequestSeed(id: "a"),
            wireGraph: graph
        )
        let scopeB = try await _TestRequestSeedWireScope.bootstrap(
            seed: TestRequestSeed(id: "b"),
            wireGraph: graph
        )
        #expect(scopeA.requestLogger.log("ping") == "[log] [a] ping")
        #expect(scopeB.requestLogger.log("ping") == "[log] [b] ping")
        // The scope-bound types are value types here; "distinct
        // instances" is observable via the seed-derived output above.
    }
}
