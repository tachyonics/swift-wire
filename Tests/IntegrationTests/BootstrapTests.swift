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

    // MARK: - `@Inject func` member injection

    @Test func injectFuncRunsAfterConstructionAndWiresState() async throws {
        // `NoteBoard.receive(message:)` is an `@Inject func` — Wire
        // resolves `NoteMessage` from the graph, calls the method
        // after `NoteBoard` is constructed, and the method's body
        // mutates the consumer's own state. Asserting the post-
        // bootstrap state proves the method ran with the right
        // resolved argument.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.noteBoard.current() == "wire said: hello from @Inject func")
    }

    @Test func injectFuncOnActorConsumerRunsThroughActorIsolation() async throws {
        // `TickCounter.bump(by:)` is an `@Inject func` on an
        // `actor` host. Wire's codegen forces `await` at the call
        // site (even though `bump(by:)` isn't itself `async`) — the
        // await pays for the isolation crossing. After bootstrap,
        // the actor's state reflects the injected increment.
        let graph = try await _WireGraph.bootstrap()
        #expect(await graph.tickCounter.ticks == 7)
    }

    // MARK: - `@Inject weak var` cycle-breaking

    @Test func weakInjectionBreaksSingletonCycle() async throws {
        // Coordinator ↔ View mutually reference each other. View
        // holds Coordinator weakly via `@Inject weak var coordinator`,
        // which excludes the edge from cycle detection. Bootstrap
        // succeeds: View constructs without Coordinator, Coordinator
        // takes View at init, then the generated bootstrap's post-
        // init block runs `view.coordinator = coordinator`. Without
        // this feature, the build would fail with a cycle error.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.coordinator.view === graph.view)
        #expect(graph.view.describeCoordinator() == "coordinator owns this view: true")
    }

    @Test func weakInjectionEstablishesPostInitReferenceWithoutRetainCycle() async throws {
        // Sanity check on the runtime semantics: the weak property
        // is *the* coordinator (not a copy), and the relationship
        // is observable through the consumer's own API. Pins the
        // contract that codegen's post-init assignment produces a
        // live weak reference, not just structural compilation.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.view.coordinator === graph.coordinator)
    }

    @Test func iuoWeakVarBreaksSingletonCycle() async throws {
        // Hub ↔ Spoke, with Spoke holding Hub weakly via the IUO form
        // `@Inject weak var hub: Hub!`. The weak edge is excluded from
        // cycle detection, so bootstrap succeeds — the `!` is ergonomic
        // only. That this builds proves the generated `spoke.hub = hub`
        // compiles against `weak var hub: Hub!` storage and the matcher's
        // `T!` normalization resolves the edge; the runtime assertions
        // pin the IUO non-optional access.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.hub.spoke === graph.spoke)
        #expect(graph.spoke.hub === graph.hub)
        #expect(graph.spoke.describeHub() == "hub owns this spoke: true")
    }

    @Test func weakInjectionOnActorRoutesThroughGeneratedSetterExtension() async throws {
        // `@Inject weak var workshop: Workshop?` on a `Toolbelt`
        // actor compiles by virtue of the synthesised
        // `_wireSetWorkshop(_:)` extension method WireGen emits;
        // direct property assignment from outside actor isolation
        // would have been rejected by Swift. Bootstrap completes,
        // the mutual reference is established post-init via
        // `await`, and the runtime relationship is observable
        // through the actor's isolated property reads.
        let graph = try await _WireGraph.bootstrap()
        let toolbeltWorkshop = await graph.toolbelt.workshop
        #expect(toolbeltWorkshop === graph.workshop)
        let workshopToolbelt = graph.workshop.toolbelt
        #expect(workshopToolbelt === graph.toolbelt)
    }

    // MARK: - `@Inject weak let` constructor injection

    @Test func weakLetInjectionDeliversNonOwningReferenceAtInit() async throws {
        // `Dashboard` holds `Telemetry` via `@Inject weak let` — delivered
        // at init (constructor injection), not post-construct. That this
        // test *builds* is the load-bearing assertion: the macro-generated
        // `init(telemetry: Telemetry?) { self.telemetry = telemetry }` has
        // to compile against `weak let` storage. At runtime the graph
        // retains the `@Singleton Telemetry` strongly, so the weak hold
        // stays valid and resolves to the same instance.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.dashboard.telemetry === graph.telemetry)
        #expect(graph.dashboard.describeTelemetry() == "telemetry id: telemetry")
    }

    @Test func unownedInjectionDeliversNonOwningReferenceAtInit() async throws {
        // `Monitor` holds `Sensor` via `@Inject unowned let` — non-owning,
        // non-optional, constructor-injected. That this builds proves the
        // generated `init(sensor: Sensor) { self.sensor = sensor }`
        // compiles against `unowned let` storage; the graph retains the
        // `@Singleton Sensor` strongly, so the unowned hold stays valid.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.monitor.sensor === graph.sensor)
        #expect(graph.monitor.describeSensor() == "sensor id: sensor")
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

    // MARK: - Multibindings

    @Test func collectedMultibindingAggregatesContributorsInRankOrder() async throws {
        // LoggingPlugin (withOrder: 1) and MetricsPlugin (withOrder: 2)
        // contribute to PluginRegistry.ordered; the injected `[any Plugin]`
        // is in rank order despite the source declaring metrics first.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.pluginHost.plugins.map { $0.label() } == ["logging", "metrics"])
    }

    @Test func mappedMultibindingKeysContributorsByAtKey() async throws {
        let graph = try await _WireGraph.bootstrap()
        let strategies = graph.strategyHost.strategies
        #expect(strategies.count == 2)
        #expect(strategies["fast"]?.run() == "fast")
        #expect(strategies["slow"]?.run() == "slow")
        #expect(strategies["missing"] == nil)
    }

    @Test func builderMultibindingFoldsToConcreteResultInRankOrder() async throws {
        // AuthMiddleware (withOrder: 1) and LoggingMiddleware (withOrder: 2)
        // fold through PipelineBuilder's buildBlock into a concrete Pipeline.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.middlewareHost.pipeline.steps == ["auth", "log"])
    }

    @Test func builderMultibindingFoldsToCollectionResult() async throws {
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.middlewareHost.list.map(\.step) == ["auth", "log"])
    }

    @Test func builderMultibindingFoldsToExistentialResult() async throws {
        // The builder folds the contributors into a single `any Middleware`
        // — exercises a result type whose string carries an `any ` prefix.
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.middlewareHost.composed.step == "auth>log")
    }

    @Test func containerMultibindingAggregatesContainerContributors() async throws {
        // The key, contributors, and consumer all live in PluginContainer,
        // so the aggregate is built in the container's own graph.
        let graph = try await _PluginContainerWireGraph.bootstrap()
        #expect(graph.pluginConsumer.plugins.map { $0.id() } == ["alpha", "beta"])
    }

    @Test func seedScopeMultibindingAggregatesScopeContributors() async throws {
        // HeaderSection and BodySection are @Scoped contributors; the
        // aggregate is built per scope (HeaderSection even reads the seed).
        let graph = try await _WireGraph.bootstrap()
        let scope = try await _ReportSeedWireScope.bootstrap(
            seed: ReportSeed(name: "Q3"),
            wireGraph: graph
        )
        #expect(scope.report.render() == ["header:Q3", "body"])
    }

    @Test func containerSeedScopeMultibindingAggregatesScopeContributors() async throws {
        // The (container, seed) cell: key declared in WidgetContainer,
        // contributors scope-bound within the container's seed scope. The
        // cross-container check allows it (container matches, scope differs).
        let containerGraph = try await _WidgetContainerWireGraph.bootstrap()
        let scope = try await _WidgetContainer_WidgetSeedWireScope.bootstrap(
            seed: WidgetSeed(theme: "dark"),
            widgetContainerWireGraph: containerGraph
        )
        #expect(scope.widgetView.render() == ["button:dark", "label"])
    }
}
