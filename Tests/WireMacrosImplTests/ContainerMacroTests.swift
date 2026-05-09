import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

/// `@Container` is a marker peer macro; expansion produces nothing. The
/// build plugin's source scan is what actually picks up the marker and
/// routes the enum's `@Provides`/nested-`@Singleton` declarations into
/// a per-container graph. These tests pin the "no peers, no
/// diagnostics" contract on the only attachment site we support — the
/// primary declaration of an enum.
final class ContainerMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Container": ContainerMacro.self
    ]

    func test_containerOnEmptyEnum_producesNoPeers() {
        assertMacroExpansion(
            """
            @Container
            enum TestContainer {
            }
            """,
            expandedSource: """
                enum TestContainer {
                }
                """,
            macros: macros
        )
    }

    func test_containerOnEnumWithStaticProperty_producesNoPeers() {
        assertMacroExpansion(
            """
            @Container
            enum TestContainer {
                static let logger = "x"
            }
            """,
            expandedSource: """
                enum TestContainer {
                    static let logger = "x"
                }
                """,
            macros: macros
        )
    }

    func test_containerOnEnumWithStaticFunc_producesNoPeers() {
        assertMacroExpansion(
            """
            @Container
            enum TestContainer {
                static func makeLogger() -> Logger {
                    Logger()
                }
            }
            """,
            expandedSource: """
                enum TestContainer {
                    static func makeLogger() -> Logger {
                        Logger()
                    }
                }
                """,
            macros: macros
        )
    }

    func test_containerOnEnumWithNestedType_producesNoPeers() {
        // Nested types like a `@Singleton struct ... { }` inside a
        // `@Container` are part of the container's graph at discovery
        // time; the macro layer doesn't transform them.
        assertMacroExpansion(
            """
            @Container
            enum TestContainer {
                struct Nested {
                }
            }
            """,
            expandedSource: """
                enum TestContainer {
                    struct Nested {
                    }
                }
                """,
            macros: macros
        )
    }

    func test_containerOnExtension_producesNoPeers() {
        // `@Container extension Foo { ... }` is the opt-in form for
        // contributing extra bindings into Foo's container. The macro
        // is still a marker — discovery uses the attribute's presence
        // on the extension to route bindings appropriately.
        assertMacroExpansion(
            """
            @Container
            extension TestContainer {
                @Provides static let extra: Extra = Extra()
            }
            """,
            expandedSource: """
                extension TestContainer {
                    @Provides static let extra: Extra = Extra()
                }
                """,
            macros: macros
        )
    }

    // The README's canonical pattern is `@Container enum`, but the
    // attribute also accepts struct/class/actor for users who prefer
    // a different namespace style. The macro stays a no-op marker on
    // every kind; discovery handles the routing identically.

    func test_containerOnStruct_producesNoPeers() {
        assertMacroExpansion(
            """
            @Container
            struct AppConfig {
                @Provides static let logger: Logger = Logger()
            }
            """,
            expandedSource: """
                struct AppConfig {
                    @Provides static let logger: Logger = Logger()
                }
                """,
            macros: macros
        )
    }

    func test_containerOnClass_producesNoPeers() {
        assertMacroExpansion(
            """
            @Container
            class TestContainer {
                @Provides static let mockLogger: Logger = MockLogger()
            }
            """,
            expandedSource: """
                class TestContainer {
                    @Provides static let mockLogger: Logger = MockLogger()
                }
                """,
            macros: macros
        )
    }

    func test_containerOnActor_producesNoPeers() {
        assertMacroExpansion(
            """
            @Container
            actor RuntimeConfig {
                @Provides static let buildNumber: Int = 42
            }
            """,
            expandedSource: """
                actor RuntimeConfig {
                    @Provides static let buildNumber: Int = 42
                }
                """,
            macros: macros
        )
    }
}
