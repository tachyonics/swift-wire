import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

/// `@Scoped(seed:)` shares its expansion code with `@Singleton`, so the
/// validation/key/init-generation behaviour is exhaustively covered by
/// `SingletonMacroTests`. These tests pin the points where `@Scoped`
/// has to behave correctly *as itself*: the attribute carries an
/// argument the macro must accept without complaint, the synthesised
/// members are the same regardless of seed type, the unsupported-
/// declaration error names `@Scoped`, and generic host types work.
final class ScopedMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Scoped": ScopedMacro.self,
        "Inject": InjectMacro.self,
        "Provides": ProvidesMacro.self,
    ]

    // MARK: - Basic expansion

    func test_scopedOnEmptyStruct_generatesEmptyInitAndKey() {
        assertMacroExpansion(
            """
            @Scoped(seed: RequestSeed.self)
            struct A {
            }
            """,
            expandedSource: """
                struct A {

                    init() {
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    func test_scopedWithOneInject_generatesParameterisedInit() {
        assertMacroExpansion(
            """
            @Scoped(seed: RequestSeed.self)
            struct A {
                @Inject var b: B
            }
            """,
            expandedSource: """
                struct A {
                    var b: B

                    init(b: B) {
                        self.b = b
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    func test_scopedInjectsSeedTypeDirectly() {
        // The seed itself is a legitimate dependency — Wire makes it
        // bindable inside the scope. From the macro's perspective this
        // is just a normal @Inject property.
        assertMacroExpansion(
            """
            @Scoped(seed: RequestSeed.self)
            struct A {
                @Inject var seed: RequestSeed
            }
            """,
            expandedSource: """
                struct A {
                    var seed: RequestSeed

                    init(seed: RequestSeed) {
                        self.seed = seed
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Generic host types

    func test_scopedOnGenericStruct_keyIsComputedAndCarriesGenericParameters() {
        // Generic types can't have `static let` with a `Self` parameter,
        // so the key falls back to a computed property — same rule as
        // `@Singleton`. Pin it so the parity stays explicit.
        assertMacroExpansion(
            """
            @Scoped(seed: RequestSeed.self)
            struct Repository<Model> {
                @Inject var data: Model
            }
            """,
            expandedSource: """
                struct Repository<Model> {
                    var data: Model

                    init(data: Model) {
                        self.data = data
                    }

                    static var key: BindingKey<Repository<Model>> {
                        BindingKey<Repository<Model>>()
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: - Different seed types share the same expansion

    func test_scopedWithDifferentSeedType_producesIdenticalMembers() {
        // The synthesised members don't reference the seed type. Two
        // `@Scoped` annotations with different seeds expand identically
        // — the seed only affects which graph partition the build
        // plugin routes the binding into.
        assertMacroExpansion(
            """
            @Scoped(seed: SQSMessage.self)
            struct Worker {
                @Inject var message: SQSMessage
            }
            """,
            expandedSource: """
                struct Worker {
                    var message: SQSMessage

                    init(message: SQSMessage) {
                        self.message = message
                    }

                    static let key = BindingKey<Worker>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Unsupported declarations

    func test_scopedOnEnum_throwsUnsupportedDeclarationError() {
        assertMacroExpansion(
            """
            @Scoped(seed: RequestSeed.self)
            enum A {
                case b
            }
            """,
            expandedSource: """
                enum A {
                    case b
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Scoped can only be applied to a struct, class, or actor.",
                    line: 1,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_scopedOnProtocol_throwsUnsupportedDeclarationError() {
        assertMacroExpansion(
            """
            @Scoped(seed: RequestSeed.self)
            protocol A {
                func b()
            }
            """,
            expandedSource: """
                protocol A {
                    func b()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Scoped can only be applied to a struct, class, or actor.",
                    line: 1,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    // MARK: - Peer role on a `@Provides` producer (Axis A)

    /// Stacked on a `@Provides` function, `@Scoped`'s peer role makes the
    /// combination legal and emits nothing — the value comes from the
    /// `@Provides` declaration; the plugin reads scope identity from the
    /// attribute. No member-role error (a function isn't a type decl).
    func test_scopedOnProvidesFunction_emitsNothingAndDoesNotError() {
        assertMacroExpansion(
            """
            @Provides @Scoped(seed: RequestSeed.self)
            static func makeFoo() -> Foo {
                Foo()
            }
            """,
            expandedSource: """
                static func makeFoo() -> Foo {
                    Foo()
                }
                """,
            macros: macros
        )
    }

    /// Same for a `@Provides` stored property.
    func test_scopedOnProvidesProperty_emitsNothingAndDoesNotError() {
        assertMacroExpansion(
            """
            @Provides @Scoped(seed: RequestSeed.self)
            static let foo: Foo = Foo()
            """,
            expandedSource: """
                static let foo: Foo = Foo()
                """,
            macros: macros
        )
    }
}
