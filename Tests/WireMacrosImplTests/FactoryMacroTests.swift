import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

final class FactoryMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Factory": FactoryMacro.self,
        "Inject": InjectMacro.self,
    ]

    // MARK: - Init synthesis from @Inject members

    func test_factoryWithInjectProperty_generatesInitFromInjectMembers() {
        // The generic parameters are assisted (not init params); only the
        // @Inject dependency flows into the generated init. No `static key` —
        // the template's identity is its FactoryKey argument.
        assertMacroExpansion(
            """
            @Factory(MyMiddleware.session)
            struct SessionMiddleware<Ctx, Reader, Sender> {
                @Inject var store: SessionStore
            }
            """,
            expandedSource: """
                struct SessionMiddleware<Ctx, Reader, Sender> {
                    var store: SessionStore

                    init(store: SessionStore) {
                        self.store = store
                    }
                }
                """,
            macros: macros
        )
    }

    func test_factoryWithNoInject_generatesEmptyInit() {
        assertMacroExpansion(
            """
            @Factory(MyMiddleware.logging)
            struct LogMiddleware<Ctx, Reader, Sender> {
            }
            """,
            expandedSource: """
                struct LogMiddleware<Ctx, Reader, Sender> {

                    init() {
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: - Access level carries onto the generated init (cross-module call)

    func test_publicFactory_generatesPublicInit() {
        // The synthesised factory's construction call may live in another
        // module, so the init must carry the type's access — the memberwise
        // init (internal) wouldn't be reachable.
        assertMacroExpansion(
            """
            @Factory(MyMiddleware.session)
            public struct SessionMiddleware<Ctx> {
                @Inject public var store: SessionStore
            }
            """,
            expandedSource: """
                public struct SessionMiddleware<Ctx> {
                    public var store: SessionStore

                    public init(store: SessionStore) {
                        self.store = store
                    }
                }
                """,
            macros: macros
        )
    }
}
