import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

/// `@Teardown` is a marker peer macro; expansion produces nothing. The
/// build plugin's source scan is what records the teardown action (a
/// `@Teardown` method on a `@Singleton`/`@Scoped` type, or a
/// `@Teardown(<action>)` on a `@Provides`). These tests pin the "no
/// peers, no diagnostics" contract on both attachment shapes.
final class TeardownMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Teardown": TeardownMacro.self
    ]

    func test_bareTeardownOnMethod_producesNoPeers() {
        assertMacroExpansion(
            """
            @Teardown
            func teardown() async throws {
            }
            """,
            expandedSource: """
                func teardown() async throws {
                }
                """,
            macros: macros
        )
    }

    func test_teardownClosureOnFunction_producesNoPeers() {
        assertMacroExpansion(
            """
            @Teardown({ (client: HTTPClient) in try await client.shutdown() })
            func makeClient() -> HTTPClient {
                HTTPClient()
            }
            """,
            expandedSource: """
                func makeClient() -> HTTPClient {
                    HTTPClient()
                }
                """,
            macros: macros
        )
    }

    func test_teardownFunctionReferenceOnFunction_producesNoPeers() {
        assertMacroExpansion(
            """
            @Teardown(shutdownClient)
            func makeClient() -> HTTPClient {
                HTTPClient()
            }
            """,
            expandedSource: """
                func makeClient() -> HTTPClient {
                    HTTPClient()
                }
                """,
            macros: macros
        )
    }
}
