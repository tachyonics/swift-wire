import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireMacrosImpl

final class SingletonMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Singleton": SingletonMacro.self,
        "Inject": InjectMacro.self,
    ]

    // MARK: - Smallest case: no @Inject properties

    func test_singletonOnEmptyStruct_generatesEmptyInitAndKey() {
        assertMacroExpansion(
            """
            @Singleton
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

    // MARK: - Single @Inject property

    func test_singletonWithOneInject_generatesParameterisedInit() {
        assertMacroExpansion(
            """
            @Singleton
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

    // MARK: - Multiple @Inject properties retain declaration order

    func test_singletonWithMultipleInjects_preservesDeclarationOrder() {
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var first: First
                @Inject var second: Second
                @Inject var third: Third
            }
            """,
            expandedSource: """
                struct A {
                    var first: First
                    var second: Second
                    var third: Third

                    init(first: First, second: Second, third: Third) {
                        self.first = first
                        self.second = second
                        self.third = third
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Non-@Inject properties are ignored

    func test_singletonIgnoresPropertiesWithoutInject() {
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var injected: Dep
                let plain: String = "hi"
                var computed: Int { 42 }
            }
            """,
            expandedSource: """
                struct A {
                    var injected: Dep
                    let plain: String = "hi"
                    var computed: Int { 42 }

                    init(injected: Dep) {
                        self.injected = injected
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Generic types stay generic

    func test_singletonOnGenericStruct_specialisesKeyToGenericInstance() {
        assertMacroExpansion(
            """
            @Singleton
            struct Repository<Model> {
                @Inject var store: Store<Model>
            }
            """,
            expandedSource: """
                struct Repository<Model> {
                    var store: Store<Model>

                    init(store: Store<Model>) {
                        self.store = store
                    }

                    static let key = BindingKey<Repository<Model>>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Access level matches the host type

    func test_singletonOnPublicStruct_emitsPublicInitAndKey() {
        assertMacroExpansion(
            """
            @Singleton
            public struct A {
                @Inject var b: B
            }
            """,
            expandedSource: """
                public struct A {
                    var b: B

                    public init(b: B) {
                        self.b = b
                    }

                    public static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    func test_singletonOnPackageStruct_emitsPackageInitAndKey() {
        assertMacroExpansion(
            """
            @Singleton
            package struct A {
            }
            """,
            expandedSource: """
                package struct A {

                    package init() {
                    }

                    package static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Class and actor variants

    func test_singletonOnClass_works() {
        assertMacroExpansion(
            """
            @Singleton
            final class A {
                @Inject var b: B
            }
            """,
            expandedSource: """
                final class A {
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

    func test_singletonOnActor_works() {
        assertMacroExpansion(
            """
            @Singleton
            actor A {
                @Inject var b: B
            }
            """,
            expandedSource: """
                actor A {
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

    // MARK: - Diagnostic: stored property the init won't initialise

    func test_singletonReportsUninitialisedStoredProperty() {
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var injected: Dep
                let uninitialised: String
            }
            """,
            expandedSource: """
                struct A {
                    var injected: Dep
                    let uninitialised: String

                    init(injected: Dep) {
                        self.injected = injected
                    }

                    static let key = BindingKey<A>()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Stored property 'uninitialised' must have a default value, be a computed property, or be marked @Inject.",
                    line: 4,
                    column: 9,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_singletonReportsMultipleUninitialisedProperties() {
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                let first: String
                let second: Int
            }
            """,
            expandedSource: """
                struct A {
                    let first: String
                    let second: Int

                    init() {
                    }

                    static let key = BindingKey<A>()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Stored property 'first' must have a default value, be a computed property, or be marked @Inject.",
                    line: 3,
                    column: 9,
                    severity: .error
                ),
                DiagnosticSpec(
                    message:
                        "Stored property 'second' must have a default value, be a computed property, or be marked @Inject.",
                    line: 4,
                    column: 9,
                    severity: .error
                ),
            ],
            macros: macros
        )
    }

    func test_singletonAllowsStaticPropertyWithoutDefault() {
        // `static` properties live on the type, not the instance, and Swift
        // requires them to have a default value at the declaration site —
        // the synthesised init never touches them, so no diagnostic should
        // fire even though no default is visible to the macro.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                static let shared: String = "hello"
                @Inject var dep: Dep
            }
            """,
            expandedSource: """
                struct A {
                    static let shared: String = "hello"
                    var dep: Dep

                    init(dep: Dep) {
                        self.dep = dep
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    func test_singletonAllowsComputedAndDefaultedPropertiesWithoutDiagnostic() {
        // Sanity check that the validation only fires on truly
        // uninitialised stored properties; computed and defaulted both
        // remain silent.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var dep: Dep
                let defaulted: String = "hi"
                var computed: Int { 42 }
            }
            """,
            expandedSource: """
                struct A {
                    var dep: Dep
                    let defaulted: String = "hi"
                    var computed: Int { 42 }

                    init(dep: Dep) {
                        self.dep = dep
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Deference to user-provided members

    func test_singletonSkipsInitGenerationWhenUserProvided() {
        // The user has their own init — possibly with extra setup or
        // assertions. The macro generates only the key.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var b: B

                init(b: B) {
                    self.b = b
                }
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

    func test_singletonSkipsKeyGenerationWhenUserProvided() {
        // The user has their own key — typically a named identifier like
        // `BindingKey<A>("custom")`. The macro generates only the init.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var b: B

                static let key = BindingKey<A>("custom-id")
            }
            """,
            expandedSource: """
                struct A {
                    var b: B

                    static let key = BindingKey<A>("custom-id")

                    init(b: B) {
                        self.b = b
                    }
                }
                """,
            macros: macros
        )
    }

    func test_singletonGeneratesNothingWhenUserProvidesBoth() {
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var b: B

                init(b: B) {
                    self.b = b
                }
                static let key = BindingKey<A>("custom-id")
            }
            """,
            expandedSource: """
                struct A {
                    var b: B

                    init(b: B) {
                        self.b = b
                    }
                    static let key = BindingKey<A>("custom-id")
                }
                """,
            macros: macros
        )
    }

    func test_singletonSuppressesUninitialisedDiagnosticWhenUserInitProvided() {
        // The user's init handles the otherwise-uninitialised property;
        // Wire's diagnostic would be redundant noise here. Swift will
        // still validate the user's init covers every stored property —
        // any miss surfaces at the user's init site, not at Wire.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                let uninitialised: String

                init(value: String) {
                    self.uninitialised = value
                }
            }
            """,
            expandedSource: """
                struct A {
                    let uninitialised: String

                    init(value: String) {
                        self.uninitialised = value
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }
}
