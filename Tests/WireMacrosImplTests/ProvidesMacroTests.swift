import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

/// `@Provides` is a marker peer macro; expansion produces nothing. The
/// build plugin's source scan is what actually picks up `@Provides`
/// declarations and wires them into the graph. These tests pin the
/// "no peers, no diagnostics" contract at every attachment site we
/// support — module-scope `let`/`func` and `static let`/`static func`
/// on a non-`@Container` enclosing type.
final class ProvidesMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Provides": ProvidesMacro.self
    ]

    func test_providesOnTopLevelLet_producesNoPeers() {
        assertMacroExpansion(
            """
            @Provides let logger = "hello"
            """,
            expandedSource: """
                let logger = "hello"
                """,
            macros: macros
        )
    }

    func test_providesOnTopLevelFunc_producesNoPeers() {
        assertMacroExpansion(
            """
            @Provides
            func makeLogger() -> Logger {
                Logger()
            }
            """,
            expandedSource: """
                func makeLogger() -> Logger {
                    Logger()
                }
                """,
            macros: macros
        )
    }

    func test_providesOnStaticLet_producesNoPeers() {
        assertMacroExpansion(
            """
            enum Config {
                @Provides static let logger = "hello"
            }
            """,
            expandedSource: """
                enum Config {
                    static let logger = "hello"
                }
                """,
            macros: macros
        )
    }

    func test_providesOnStaticFunc_producesNoPeers() {
        assertMacroExpansion(
            """
            enum Config {
                @Provides
                static func makeLogger() -> Logger {
                    Logger()
                }
            }
            """,
            expandedSource: """
                enum Config {
                    static func makeLogger() -> Logger {
                        Logger()
                    }
                }
                """,
            macros: macros
        )
    }
}
