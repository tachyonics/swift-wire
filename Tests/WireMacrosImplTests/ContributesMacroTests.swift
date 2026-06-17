import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

/// `@Contributes(to:)` is a marker peer macro; expansion produces
/// nothing. The build plugin's source scan is what records the
/// contribution and folds it into the aggregate. These tests pin the
/// "no peers, no diagnostics" contract across the contribution forms —
/// bare, `withOrder:`, and `atKey:` — and on the typical
/// `@Singleton @Contributes` pairing.
final class ContributesMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Contributes": ContributesMacro.self
    ]

    func test_contributesOnType_producesNoPeers() {
        assertMacroExpansion(
            """
            @Contributes(to: App.services)
            struct AuthService {
            }
            """,
            expandedSource: """
                struct AuthService {
                }
                """,
            macros: macros
        )
    }

    func test_contributesWithOrder_producesNoPeers() {
        assertMacroExpansion(
            """
            @Contributes(to: App.middleware, withOrder: 2)
            struct LoggingMiddleware {
            }
            """,
            expandedSource: """
                struct LoggingMiddleware {
                }
                """,
            macros: macros
        )
    }

    func test_contributesWithAtKey_producesNoPeers() {
        assertMacroExpansion(
            """
            @Contributes(to: App.strategies, atKey: "fast")
            struct FastStrategy {
            }
            """,
            expandedSource: """
                struct FastStrategy {
                }
                """,
            macros: macros
        )
    }

    func test_contributesAlongsideSingleton_stripsOnlyContributes() {
        // The expansion harness strips `@Contributes` (no peers) and
        // leaves `@Singleton` for its own macro to expand — here
        // unexpanded since only `Contributes` is registered. Confirms
        // the two attributes compose without `@Contributes` perturbing
        // the declaration.
        assertMacroExpansion(
            """
            @Singleton
            @Contributes(to: App.services)
            struct AuthService {
            }
            """,
            expandedSource: """
                @Singleton
                struct AuthService {
                }
                """,
            macros: macros
        )
    }
}
