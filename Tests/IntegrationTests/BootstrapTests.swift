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
}
