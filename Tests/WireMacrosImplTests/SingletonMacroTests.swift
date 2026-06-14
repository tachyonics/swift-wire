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

    // MARK: - `@Inject weak var` is excluded from synthesised init

    func test_injectWeakVar_excludedFromSynthesisedInitParameters() {
        // The `weak` modifier means the property is wired via the
        // build plugin's post-init assignment block, not via the
        // init's parameter list. The synthesised init takes no
        // parameters; the weak property stays as Swift-native
        // `weak var x: T?` storage that defaults to nil.
        assertMacroExpansion(
            """
            @Singleton
            final class View {
                @Inject weak var coordinator: Coordinator?
            }
            """,
            expandedSource: """
                final class View {
                    weak var coordinator: Coordinator?

                    init() {
                    }

                    static let key = BindingKey<View>()
                }
                """,
            macros: macros
        )
    }

    func test_injectWeakLet_includedInSynthesisedInitParameters() {
        // Contrast with `weak var`: a `weak let` is delivered at
        // construction (the single write a `let` allows), so the
        // synthesised init takes it as a parameter and assigns it. It is
        // constructor-injected — a cycle participant, not a breaker. See
        // Documentation/Notes/OptionalMatchingAndCycles.md.
        assertMacroExpansion(
            """
            @Singleton
            final class View {
                @Inject weak let coordinator: Coordinator?
            }
            """,
            expandedSource: """
                final class View {
                    weak let coordinator: Coordinator?

                    init(coordinator: Coordinator?) {
                        self.coordinator = coordinator
                    }

                    static let key = BindingKey<View>()
                }
                """,
            macros: macros
        )
    }

    func test_injectWeakVar_coexistsWithStrongInjectInit() {
        // The "init OR properties, never both" rule has one
        // exception: weak `@Inject` properties may coexist with
        // a user-written `@Inject init`. Swift won't let init
        // parameters be `weak`, so the combination is the only
        // way to express "custom init body + weak deps." The
        // macro emits no init (the user's @Inject init is the
        // source of truth) and the weak property stays as
        // storage; codegen post-init-assigns it.
        assertMacroExpansion(
            """
            @Singleton
            final class View {
                @Inject weak var coordinator: Coordinator?

                let name: String

                @Inject
                init(name: String) {
                    self.name = name
                }
            }
            """,
            expandedSource: """
                final class View {
                    weak var coordinator: Coordinator?

                    let name: String
                    init(name: String) {
                        self.name = name
                    }

                    static let key = BindingKey<View>()
                }
                """,
            macros: macros
        )
    }

    func test_injectWeakVarAlongsideStrongInjectVar_synthesisesInitForStrongOnly() {
        // Mixed weak + non-weak `@Inject` properties: synthesised
        // init parameters cover the non-weak ones only. Weak slots
        // are post-init assigned by codegen.
        assertMacroExpansion(
            """
            @Singleton
            final class View {
                @Inject var name: String
                @Inject weak var coordinator: Coordinator?
            }
            """,
            expandedSource: """
                final class View {
                    var name: String
                    weak var coordinator: Coordinator?

                    init(name: String) {
                        self.name = name
                    }

                    static let key = BindingKey<View>()
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
        // Generic types can't have `static let` properties that refer
        // to their generic parameters — Swift errors with "static
        // stored properties not supported in generic types". The
        // macro emits a computed `static var` for generic types so
        // each specialisation gets its own key instance.
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

                    static var key: BindingKey<Repository<Model>> {
                        BindingKey<Repository<Model>>()
                    }
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

    // MARK: - Deference to user-provided members

    func test_singletonSkipsInitGenerationWhenInjectInitProvided() {
        // The user has their own init marked @Inject. The init's parameters
        // are the dependency declaration; stored properties are just
        // storage. The macro generates only the key.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                let b: B

                @Inject
                init(b: B) {
                    self.b = b
                }
            }
            """,
            expandedSource: """
                struct A {
                    let b: B
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
                let b: B

                @Inject
                init(b: B) {
                    self.b = b
                }
                static let key = BindingKey<A>("custom-id")
            }
            """,
            expandedSource: """
                struct A {
                    let b: B
                    init(b: B) {
                        self.b = b
                    }
                    static let key = BindingKey<A>("custom-id")
                }
                """,
            macros: macros
        )
    }

    func test_singletonSuppressesUninitialisedDiagnosticWhenInjectInitProvided() {
        // The user's @Inject-marked init handles the otherwise-
        // uninitialised property; Wire's diagnostic would be redundant
        // noise. Swift will still validate the user's init covers every
        // stored property — any miss surfaces at the user's init site, not
        // at Wire.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                let uninitialised: String

                @Inject
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

    // MARK: - @Inject on init: validation errors

    func test_singletonReportsUnmarkedUserInit() {
        // User-provided init with no @Inject anywhere is ambiguous — Wire
        // doesn't know whether the parameters are dependencies. Strict
        // rule: the user must mark exactly one init.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                init(b: B) {
                    self.b = b
                }
                let b: B
            }
            """,
            expandedSource: """
                struct A {
                    init(b: B) {
                        self.b = b
                    }
                    let b: B

                    static let key = BindingKey<A>()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "User-provided initialiser must be marked @Inject so Wire knows which one to call. Either add @Inject to this initialiser, or remove the initialiser entirely and let Wire generate one from @Inject stored properties.",
                    line: 3,
                    column: 5,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_singletonReportsUnmarkedParameterlessInit() {
        // Even a parameterless init must be marked @Inject for
        // consistency. Without the rule, the difference between "no init"
        // (macro generates) and "init() {}" (silently used) is invisible.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                init() {
                }
            }
            """,
            expandedSource: """
                struct A {
                    init() {
                    }

                    static let key = BindingKey<A>()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "User-provided initialiser must be marked @Inject so Wire knows which one to call. Either add @Inject to this initialiser, or remove the initialiser entirely and let Wire generate one from @Inject stored properties.",
                    line: 3,
                    column: 5,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_singletonReportsMultipleInjectInits() {
        // Wire must call exactly one init at bootstrap; multiple marked
        // inits is ambiguous.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                let b: B

                @Inject
                init(b: B) {
                    self.b = b
                }

                @Inject
                init(b: B, extra: Int) {
                    self.b = b
                }
            }
            """,
            expandedSource: """
                struct A {
                    let b: B
                    init(b: B) {
                        self.b = b
                    }
                    init(b: B, extra: Int) {
                        self.b = b
                    }

                    static let key = BindingKey<A>()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Only one initialiser can be marked @Inject. Remove @Inject from the others.",
                    line: 5,
                    column: 5,
                    severity: .error
                ),
                DiagnosticSpec(
                    message: "Only one initialiser can be marked @Inject. Remove @Inject from the others.",
                    line: 10,
                    column: 5,
                    severity: .error
                ),
            ],
            macros: macros
        )
    }

    func test_singletonReportsInjectOnInitAndProperty() {
        // @Inject on both an init and a property is two declarations of
        // the same intent. The marked init's params are the deps; @Inject
        // on properties is redundant and ambiguous.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject var b: B

                @Inject
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
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Inject is on both an initialiser and a stored property. Pick one source of truth — either the @Inject-marked initialiser declares dependencies via its parameters, or @Inject-marked properties declare them via Wire's auto-generated init.",
                    line: 5,
                    column: 5,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    // MARK: - @Inject on init: happy paths

    func test_singletonAllowsInjectInitWithTransformation() {
        // The canonical "transformation" use case: stored property doesn't
        // directly correspond to what's injected; the init does the work.
        assertMacroExpansion(
            """
            @Singleton
            struct CacheLayer {
                let cache: Cache

                @Inject
                init(repository: Repository) {
                    self.cache = Cache(backedBy: repository)
                }
            }
            """,
            expandedSource: """
                struct CacheLayer {
                    let cache: Cache
                    init(repository: Repository) {
                        self.cache = Cache(backedBy: repository)
                    }

                    static let key = BindingKey<CacheLayer>()
                }
                """,
            macros: macros
        )
    }

    func test_singletonAllowsMultipleInitsWithOneMarked() {
        // Multiple inits are fine as long as exactly one is marked.
        // Unmarked inits exist as ordinary Swift inits but Wire ignores
        // them — they're available for testing, manual construction, etc.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                let b: B

                @Inject
                init(b: B) {
                    self.b = b
                }

                init(testValue: B) {
                    self.b = testValue
                }
            }
            """,
            expandedSource: """
                struct A {
                    let b: B
                    init(b: B) {
                        self.b = b
                    }

                    init(testValue: B) {
                        self.b = testValue
                    }

                    static let key = BindingKey<A>()
                }
                """,
            macros: macros
        )
    }

    // MARK: - Unsupported declarations

    func test_singletonOnEnum_throwsUnsupportedDeclarationError() {
        // `@Singleton` only applies to struct/class/actor. Applying it to
        // an enum causes the macro to throw `SingletonMacroError.unsupportedDeclaration`,
        // which the macro framework surfaces as a diagnostic at the
        // attribute site.
        assertMacroExpansion(
            """
            @Singleton
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
                    message: "@Singleton can only be applied to a struct, class, or actor.",
                    line: 1,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_singletonOnProtocol_throwsUnsupportedDeclarationError() {
        assertMacroExpansion(
            """
            @Singleton
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
                    message: "@Singleton can only be applied to a struct, class, or actor.",
                    line: 1,
                    column: 1,
                    severity: .error
                )
            ],
            macros: macros
        )
    }

    func test_singletonAllowsInjectParameterlessInit() {
        // @Inject init() {} is the explicit "construct A() with no
        // dependencies" form. Equivalent in behaviour to the no-user-init
        // case (Wire generates init() {}) but explicit at the source.
        assertMacroExpansion(
            """
            @Singleton
            struct A {
                @Inject
                init() {
                }
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
}
