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
}
