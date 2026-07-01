import Testing

@testable import WireGenCore

@Suite("CodeEmission")
struct CodeEmissionTests {
    private func singleton(
        _ name: String,
        qualifiedTypeName: String? = nil,
        dependencies: [(name: String?, type: String)] = []
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .injectInitParameter,
                location: mockLocation("\(name).swift")
            )
        }
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                qualifiedTypeName: qualifiedTypeName,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps,
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    private func providerProperty(
        _ accessPath: String,
        boundType: String
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                originModule: testModule
            )
        )
    }

    private func providerFunction(
        _ accessPath: String,
        boundType: String,
        dependencies: [(name: String?, type: String)] = []
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .providerFunctionParameter,
                location: mockLocation("\(accessPath).swift")
            )
        }
        return .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .function,
                dependencies: deps,
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                originModule: testModule
            )
        )
    }

    /// An `@Singleton(as: Identity.self)` lift node: generic over one
    /// constrained parameter, injecting it as a bare dependency.
    private func liftNode(
        _ typeName: String,
        identity: String,
        parameter: String,
        constraint: String,
        depName: String
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: typeName,
                typeKind: "struct",
                genericParameterNames: [parameter],
                genericParameterConstraints: [parameter: constraint],
                explicitIdentity: identity,
                dependencies: [
                    DependencyParameter(
                        name: depName,
                        type: parameter,
                        kind: .injectInitParameter,
                        location: mockLocation("\(typeName).swift")
                    )
                ],
                location: mockLocation("\(typeName).swift"),
                originModule: testModule
            )
        )
    }

    /// Like `liftNode` but without an explicit `@Singleton(as:)` identity — a
    /// plain constrained generic `@Singleton`, keyed by its structural identity
    /// (`Controller<some TaskRepo>`) and emitted as a nested field.
    private func structuralLiftNode(
        _ typeName: String,
        parameter: String,
        constraint: String,
        depName: String
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: typeName,
                typeKind: "struct",
                genericParameterNames: [parameter],
                genericParameterConstraints: [parameter: constraint],
                dependencies: [
                    DependencyParameter(
                        name: depName,
                        type: parameter,
                        kind: .injectInitParameter,
                        location: mockLocation("\(typeName).swift")
                    )
                ],
                location: mockLocation("\(typeName).swift"),
                originModule: testModule
            )
        )
    }

    /// Build a singleton with strong init deps plus zero or more
    /// member injections. Used to verify the post-init emission block:
    /// strong deps appear in the init args (filtered cleanly from
    /// member injections); member injections emit as a separate block
    /// after the construction sequence with one line per injection
    /// chosen by `Shape`. `typeKind` defaults to "class" but tests
    /// pass `"actor"` to verify the codegen's isolation-crossing
    /// `await` prefix for actor consumers.
    private func singletonWithMixedStrongAndMemberInjections(
        _ name: String,
        typeKind: String = "class",
        strongDeps: [(name: String?, type: String)] = [],
        memberInjections: [MemberInjection] = []
    ) -> DiscoveredBinding {
        let strong = strongDeps.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .injectInitParameter,
                location: mockLocation("\(name).swift")
            )
        }
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: typeKind,
                genericParameterNames: [],
                dependencies: strong,
                location: mockLocation("\(name).swift"),
                memberInjections: memberInjections,
                originModule: testModule
            )
        )
    }

    /// Build a `.propertyAssignment` member injection for a weak var
    /// sugar test case. Single parameter, sync, non-throwing.
    private func propertyAssignmentInjection(
        propertyName: String,
        type: String
    ) -> MemberInjection {
        MemberInjection(
            shape: .propertyAssignment(propertyName: propertyName),
            parameters: [
                DependencyParameter(
                    name: nil,
                    type: type,
                    kind: .injectMethodParameter,
                    location: mockLocation("\(propertyName).swift")
                )
            ],
            location: mockLocation("\(propertyName).swift")
        )
    }

    /// Build a `.methodCall` member injection for an `@Inject func`
    /// test case. Parameters are passed by `(label, type)`; effects
    /// drive the call prefix.
    private func methodCallInjection(
        methodName: String,
        parameters: [(name: String?, type: String)],
        isAsync: Bool = false,
        isThrowing: Bool = false
    ) -> MemberInjection {
        MemberInjection(
            shape: .methodCall(methodName: methodName),
            parameters: parameters.map {
                DependencyParameter(
                    name: $0.name,
                    type: $0.type,
                    kind: .injectMethodParameter,
                    location: mockLocation("\(methodName).swift")
                )
            },
            isAsync: isAsync,
            isThrowing: isThrowing,
            location: mockLocation("\(methodName).swift")
        )
    }

    // MARK: - Member injection post-init wiring

    @Test func propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction() {
        // Coordinator → View (strong init dep); View → Coordinator
        // (weak var sugar → `.propertyAssignment` member injection).
        // Topo sort gives [View, Coordinator]. View's init takes no
        // params (the member injection doesn't go through init); the
        // post-init block emits `view.coordinator = coordinator`
        // after both locals exist.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let view: View
                let coordinator: Coordinator
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let view = View()
                let coordinator = Coordinator(view: view)
                view.coordinator = coordinator
                return _WireGraph(view: view, coordinator: coordinator)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singletonWithMixedStrongAndMemberInjections(
                    "View",
                    memberInjections: [
                        propertyAssignmentInjection(
                            propertyName: "coordinator",
                            type: "Coordinator"
                        )
                    ]
                ),
                singleton(
                    "Coordinator",
                    dependencies: [(name: "view", type: "View")]
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func methodCallMemberInjectionEmitsAsMethodCallAfterConstruction() {
        // `@Inject func receiveCoordinator(_ coordinator: Coordinator)`
        // becomes a `.methodCall` member injection. Codegen emits
        // `view.receiveCoordinator(coordinator)` post-init — note the
        // wildcard parameter label is omitted at the call site, same
        // as init parameters.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let view: View
                let coordinator: Coordinator
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let view = View()
                let coordinator = Coordinator(view: view)
                view.receiveCoordinator(coordinator)
                return _WireGraph(view: view, coordinator: coordinator)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singletonWithMixedStrongAndMemberInjections(
                    "View",
                    memberInjections: [
                        methodCallInjection(
                            methodName: "receiveCoordinator",
                            parameters: [(name: nil, type: "Coordinator")]
                        )
                    ]
                ),
                singleton(
                    "Coordinator",
                    dependencies: [(name: "view", type: "View")]
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func asyncThrowingMethodCallInjectionGetsTryAwaitPrefix() {
        // An `@Inject func setup(db:) async throws` injection emits
        // `try await consumer.setup(db: db)` at the post-init call
        // site — effect-aware emission applies to member injection
        // calls the same way it applies to construction calls.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let view: View
                let database: Database
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let view = View()
                let database = Database()
                try await view.setup(db: database)
                return _WireGraph(view: view, database: database)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singletonWithMixedStrongAndMemberInjections(
                    "View",
                    memberInjections: [
                        methodCallInjection(
                            methodName: "setup",
                            parameters: [(name: "db", type: "Database")],
                            isAsync: true,
                            isThrowing: true
                        )
                    ]
                ),
                singleton("Database"),
            ]
        )
        #expect(output == expected)
    }

    @Test func propertyAssignmentOnActorConsumerRoutesThroughGeneratedSetterExtension() {
        // `@Inject weak var` on an actor host can't use direct
        // property assignment from outside isolation. The codegen
        // routes the write through a synthesised setter extension
        // method (`_wireSet<Property>`) and the post-init call site
        // crosses isolation via `await`. The extension itself
        // emits AFTER the struct/bootstrap blocks at module scope,
        // grouped per host type.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let view: View
                let coordinator: Coordinator
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let view = View()
                let coordinator = Coordinator(view: view)
                await view._wireSetCoordinator(coordinator)
                return _WireGraph(view: view, coordinator: coordinator)
            }

            extension View {
                func _wireSetCoordinator(_ value: Coordinator) {
                    self.coordinator = value
                }
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singletonWithMixedStrongAndMemberInjections(
                    "View",
                    typeKind: "actor",
                    memberInjections: [
                        propertyAssignmentInjection(
                            propertyName: "coordinator",
                            type: "Coordinator"
                        )
                    ]
                ),
                singleton(
                    "Coordinator",
                    dependencies: [(name: "view", type: "View")]
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func methodCallOnActorConsumerForcesAwaitEvenForSyncMethod() {
        // Calling any method on an actor from outside its isolation
        // requires `await`, regardless of whether the method itself
        // is declared `async`. The codegen forces the await prefix
        // for actor consumers; same method on a class consumer would
        // emit no prefix at all.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let view: View
                let coordinator: Coordinator
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let view = View()
                let coordinator = Coordinator(view: view)
                await view.receiveCoordinator(coordinator)
                return _WireGraph(view: view, coordinator: coordinator)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singletonWithMixedStrongAndMemberInjections(
                    "View",
                    typeKind: "actor",
                    memberInjections: [
                        methodCallInjection(
                            methodName: "receiveCoordinator",
                            parameters: [(name: nil, type: "Coordinator")]
                        )
                    ]
                ),
                singleton(
                    "Coordinator",
                    dependencies: [(name: "view", type: "View")]
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func throwingMethodCallOnActorConsumerGetsTryAwaitPrefix() {
        // Actor + throws → `try await`. The await is still forced by
        // the isolation crossing; the try is added for the method's
        // own `throws`.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let validator: Validator
                let policy: Policy
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let validator = Validator()
                let policy = Policy()
                try await validator.applyPolicy(policy)
                return _WireGraph(validator: validator, policy: policy)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singletonWithMixedStrongAndMemberInjections(
                    "Validator",
                    typeKind: "actor",
                    memberInjections: [
                        methodCallInjection(
                            methodName: "applyPolicy",
                            parameters: [(name: nil, type: "Policy")],
                            isThrowing: true
                        )
                    ]
                ),
                singleton("Policy"),
            ]
        )
        #expect(output == expected)
    }

    @Test func noMemberInjectionsMeansNoPostInitBlockEmitted() {
        // Regression guard: a graph with no member injections emits
        // no post-init lines. The existing two-binding output shape
        // (construction + return) is byte-for-byte unchanged.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let b: B
                let a: A
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let b = B()
                let a = A(b: b)
                return _WireGraph(b: b, a: a)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("B"),
                singleton("A", dependencies: [(name: "b", type: "B")]),
            ]
        )
        #expect(output == expected)
    }

    @Test func emptyGraphProducesBareBootstrap() {
        // Empty graph still emits a valid struct so consumers can call
        // `_Wire.bootstrap()` unconditionally. The free function
        // is also emitted (returning the empty memberwise init) so the
        // delegation shape is uniform across empty and non-empty graphs.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                _WireGraph()
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        #expect(renderWireGraph(imports: [], topologicalOrder: []) == expected)
    }

    @Test func singleNoDependencySingleton() {
        // Construction lives in a free `_wireBootstrap()` at module
        // scope. From there, bare references resolve to module scope
        // without going through `_WireGraph`'s instance members.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let a: A
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let a = A()
                return _WireGraph(a: a)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        #expect(
            renderWireGraph(imports: [], topologicalOrder: [singleton("A")]) == expected
        )
    }

    @Test func threeNodeChainConstructsInDependencyOrder() {
        // C → B → A. Each constructor's argument is an in-scope local
        // bound by a preceding statement.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let c: C
                let b: B
                let a: A
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let c = C()
                let b = B(c: c)
                let a = A(b: b)
                return _WireGraph(c: c, b: b, a: a)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("C"),
                singleton("B", dependencies: [(name: "c", type: "C")]),
                singleton("A", dependencies: [(name: "b", type: "B")]),
            ]
        )
        #expect(output == expected)
    }

    @Test func wildcardLabelOmittedFromCallSite() {
        // `init(_ a: A)` — the call site must omit the label entirely;
        // emitting `X(_: a)` would be a compile error in the consumer.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let a: A
                let x: X
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let a = A()
                let x = X(a)
                return _WireGraph(a: a, x: x)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("A"),
                singleton("X", dependencies: [(name: nil, type: "A")]),
            ]
        )
        #expect(output == expected)
    }

    @Test func mixedWildcardAndLabeledArguments() {
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let a: A
                let b: B
                let x: X
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let a = A()
                let b = B()
                let x = X(a, second: b)
                return _WireGraph(a: a, b: b, x: x)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("A"),
                singleton("B"),
                singleton(
                    "X",
                    dependencies: [(name: nil, type: "A"), (name: "second", type: "B")]
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func acronymsArePreservedInPropertyNames() {
        // Naive lowercasing keeps internal acronym case intact:
        // `DynamoDBTaskRepository` → `dynamoDBTaskRepository`.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let dynamoDBTaskRepository: DynamoDBTaskRepository
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let dynamoDBTaskRepository = DynamoDBTaskRepository()
                return _WireGraph(dynamoDBTaskRepository: dynamoDBTaskRepository)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        #expect(
            renderWireGraph(
                imports: [],
                topologicalOrder: [singleton("DynamoDBTaskRepository")]
            ) == expected
        )
    }

    // MARK: - @Provides construction

    @Test func providerPropertyConstructionIsBareReference() {
        // @Provides let logger: Logger = ... → `let logger = logger`
        // inside `_wireBootstrap()`. Swift's let-shadowing resolves the
        // RHS to module scope before the local binds, so the same
        // identifier on both sides works correctly.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let logger: Logger
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let logger = logger
                return _WireGraph(logger: logger)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [providerProperty("logger", boundType: "Logger")]
        )
        #expect(output == expected)
    }

    @Test func providerWithDottedAccessPathPreservesNamespace() {
        // Static @Provides on `enum Config` → `Config.databaseURL`.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let database: Database
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let database = Config.databaseURL
                return _WireGraph(database: database)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty("Config.databaseURL", boundType: "Database")
            ]
        )
        #expect(output == expected)
    }

    @Test func providerFunctionConstructionCallsWithResolvedArguments() {
        // @Provides func makeRepo(table:) -> Repository, with the table
        // dep coming from another @Provides.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let taskTable: TaskTable
                let repository: Repository
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let taskTable = taskTable
                let repository = makeRepo(table: taskTable)
                return _WireGraph(taskTable: taskTable, repository: repository)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty("taskTable", boundType: "TaskTable"),
                providerFunction(
                    "makeRepo",
                    boundType: "Repository",
                    dependencies: [(name: "table", type: "TaskTable")]
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func mixedSingletonAndProviderConstruction() {
        // The realistic pipeline: a @Provides supplies a primitive
        // (Logger), a @Singleton consumes it.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let logger: Logger
                let userService: UserService
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let logger = logger
                let userService = UserService(logger: logger)
                return _WireGraph(logger: logger, userService: userService)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty("logger", boundType: "Logger"),
                singleton(
                    "UserService",
                    dependencies: [(name: "logger", type: "Logger")]
                ),
            ]
        )
        #expect(output == expected)
    }

    // MARK: - Sanitisation

    @Test func genericInstantiationProducesOfSeparatedPropertyName() {
        // Repository<TaskTable> → repositoryOfTaskTable. The bound
        // type is preserved verbatim in the construction call.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let repositoryOfTaskTable: Repository<TaskTable>
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let repositoryOfTaskTable = makeRepo()
                return _WireGraph(repositoryOfTaskTable: repositoryOfTaskTable)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerFunction("makeRepo", boundType: "Repository<TaskTable>")
            ]
        )
        #expect(output == expected)
    }

    @Test func multipleGenericParametersUseAndSeparator() {
        // Pair<Left, Right> → pairOfLeftAndRight.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let pairOfLeftAndRight: Pair<Left, Right>
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let pairOfLeftAndRight = makePair()
                return _WireGraph(pairOfLeftAndRight: pairOfLeftAndRight)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerFunction("makePair", boundType: "Pair<Left, Right>")
            ]
        )
        #expect(output == expected)
    }

    // MARK: - Imports

    @Test func importsAreEmittedSortedAndDeduplicated() {
        let expected = """
            // Generated by WireGen — do not edit.

            import Bar
            import Baz
            import Foo

            internal struct _WireGraph {
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                _WireGraph()
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: ["import Foo", "import Bar", "import Foo", "import Baz"],
            topologicalOrder: []
        )
        #expect(output == expected)
    }

    @Test func importsArePreservedVerbatimWithModifiers() {
        // Access modifiers like @testable and @_implementationOnly are
        // captured verbatim by `discoverImports` and emitted as-is.
        let expected = """
            // Generated by WireGen — do not edit.

            @_implementationOnly import OSLog
            @testable import Internals
            import Foundation

            internal struct _WireGraph {
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                _WireGraph()
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [
                "import Foundation",
                "@testable import Internals",
                "@_implementationOnly import OSLog",
            ],
            topologicalOrder: []
        )
        #expect(output == expected)
    }

    // MARK: - Per-container structs

    @Test func singleContainerEmitsItsOwnStructAlongsideEmptyDefault() {
        // When the user has only @Container-routed bindings (no
        // module-scope ones), the default `_WireGraph` is still emitted
        // as an empty struct so consumers can call its bootstrap
        // unconditionally; the container struct emits alongside it.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                _WireGraph()
            }

            internal struct _TestContainerWireGraph {
                let logger: Logger
            }

            private func _wireBootstrapTestContainer() async throws -> _TestContainerWireGraph {
                let logger = TestContainer.logger
                return _TestContainerWireGraph(logger: logger)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
                static func bootstrapTestContainer() async throws -> _TestContainerWireGraph {
                    try await _wireBootstrapTestContainer()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [],
            containerTopologicalOrders: [
                "TestContainer": [providerProperty("TestContainer.logger", boundType: "Logger")]
            ]
        )
        #expect(output == expected)
    }

    @Test func defaultAndContainerBothEmitSideBySide() {
        // The default graph and a container coexist independently —
        // each gets its own struct + bootstrap free function. Bindings
        // are scoped to their respective graphs; nothing crosses.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
                let logger: Logger
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                let logger = Logger()
                return _WireGraph(logger: logger)
            }

            internal struct _TestContainerWireGraph {
                let logger: Logger
            }

            private func _wireBootstrapTestContainer() async throws -> _TestContainerWireGraph {
                let logger = TestContainer.mockLogger
                return _TestContainerWireGraph(logger: logger)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
                static func bootstrapTestContainer() async throws -> _TestContainerWireGraph {
                    try await _wireBootstrapTestContainer()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [singleton("Logger")],
            containerTopologicalOrders: [
                "TestContainer": [providerProperty("TestContainer.mockLogger", boundType: "Logger")]
            ]
        )
        #expect(output == expected)
    }

    @Test func nestedSingletonUsesQualifiedTypeNameForConstructionAndStoredPropertyType() {
        // A `@Singleton` declared inside a `@Container` has a qualified
        // type name (`TestContainer.MockService`). Both the stored-
        // property type annotation and the construction call use the
        // qualified form — required because `_<Container>WireGraph`
        // and its `_wireBootstrap...` free function live at module
        // scope, where unqualified `MockService` doesn't resolve.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                _WireGraph()
            }

            internal struct _TestContainerWireGraph {
                let mockService: TestContainer.MockService
            }

            private func _wireBootstrapTestContainer() async throws -> _TestContainerWireGraph {
                let mockService = TestContainer.MockService()
                return _TestContainerWireGraph(mockService: mockService)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
                static func bootstrapTestContainer() async throws -> _TestContainerWireGraph {
                    try await _wireBootstrapTestContainer()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [],
            containerTopologicalOrders: [
                "TestContainer": [
                    singleton(
                        "MockService",
                        qualifiedTypeName: "TestContainer.MockService"
                    )
                ]
            ]
        )
        #expect(output == expected)
    }

    @Test func multipleContainersAreEmittedInSortedOrder() {
        // Container ordering in the output is deterministic — sorted
        // alphabetically by container name. Critical so successive
        // builds of the same source produce byte-identical output.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph {
            }

            private func _wireBootstrap() async throws -> _WireGraph {
                _WireGraph()
            }

            internal struct _AlphaWireGraph {
                let a: A
            }

            private func _wireBootstrapAlpha() async throws -> _AlphaWireGraph {
                let a = Alpha.a
                return _AlphaWireGraph(a: a)
            }

            internal struct _BravoWireGraph {
                let b: B
            }

            private func _wireBootstrapBravo() async throws -> _BravoWireGraph {
                let b = Bravo.b
                return _BravoWireGraph(b: b)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph {
                    try await _wireBootstrap()
                }
                static func bootstrapAlpha() async throws -> _AlphaWireGraph {
                    try await _wireBootstrapAlpha()
                }
                static func bootstrapBravo() async throws -> _BravoWireGraph {
                    try await _wireBootstrapBravo()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [],
            containerTopologicalOrders: [
                // Insertion order intentionally non-alphabetical to
                // confirm sorted output.
                "Bravo": [providerProperty("Bravo.b", boundType: "B")],
                "Alpha": [providerProperty("Alpha.a", boundType: "A")],
            ]
        )
        #expect(output == expected)
    }

    // MARK: - renderWireKeyChecks

    /// Build a keyed `@Provides` property binding for the key-checks
    /// suite — like `providerProperty` but with `keyIdentifier`.
    private func keyedProperty(
        _ accessPath: String,
        boundType: String,
        key: String,
        line: Int = 1,
        column: Int = 1,
        sourcePath: String? = nil
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: WireGenCore.SourceLocation(
                    file: sourcePath ?? "\(accessPath).swift",
                    line: line,
                    column: column
                ),
                keyIdentifier: key,
                originModule: testModule
            )
        )
    }

    /// Build a singleton with one keyed `@Inject` dependency, located
    /// at the given line/column. Lets each test pin a precise
    /// `#sourceLocation` for the assertion call.
    private func consumerWithKeyedDep(
        _ name: String,
        depName: String,
        depType: String,
        depKey: String,
        depLine: Int = 1,
        depColumn: Int = 1,
        depSourcePath: String? = nil
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: depName,
                        type: depType,
                        kind: .injectProperty,
                        location: WireGenCore.SourceLocation(
                            file: depSourcePath ?? "\(name).swift",
                            line: depLine,
                            column: depColumn
                        ),
                        keyIdentifier: depKey
                    )
                ],
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    @Test func keyChecksEmptyInputProducesHeaderOnlyFile() {
        // No bindings at all → file is just the header comment, no
        // functions. SPM still gets the declared output file.
        let output = renderWireKeyChecks(imports: [], allBindings: [])
        #expect(output.contains("// Generated by WireGen"))
        #expect(!output.contains("_wireTypeCheck_"))
        #expect(!output.contains("_check"))
    }

    @Test func keyChecksUnkeyedBindingsProduceNoFunctions() {
        // Unkeyed `@Provides` and `@Inject` don't participate in the
        // key-check file at all — there's nothing to check.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                providerProperty("logger", boundType: "Logger"),
                singleton("App"),
            ]
        )
        #expect(!output.contains("_wireTypeCheck_"))
    }

    @Test func keyedProviderProducesCheckFunction() {
        // A single keyed `@Provides` produces one check function with
        // one `_check` call wrapped in `#sourceLocation` directives.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty(
                    "primaryDB",
                    boundType: "Database",
                    key: "Database.primary",
                    line: 5,
                    sourcePath: "App.swift"
                )
            ]
        )
        #expect(output.contains("private func _wireTypeCheck_1()"))
        #expect(output.contains("func _check<T>(_: BindingKey<T>, _: T.Type) {}"))
        #expect(output.contains("#sourceLocation(file: \"App.swift\", line: 5)"))
        #expect(output.contains("_check(Database.primary, Database.self)"))
        #expect(output.contains("#sourceLocation()"))
    }

    @Test func keyedDependencyProducesCheckFunction() {
        // The consumer side also contributes a check site: a keyed
        // `@Inject` on a property.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                consumerWithKeyedDep(
                    "UserRepo",
                    depName: "db",
                    depType: "Database",
                    depKey: "Database.primary",
                    depLine: 7,
                    depSourcePath: "UserRepo.swift"
                )
            ]
        )
        #expect(output.contains("private func _wireTypeCheck_1()"))
        #expect(output.contains("#sourceLocation(file: \"UserRepo.swift\", line: 7)"))
        #expect(output.contains("_check(Database.primary, Database.self)"))
    }

    @Test func sameKeyAndTypeAtMultipleSitesDedupesToOneFunction() {
        // Producer + two consumers all using `(Database.primary,
        // Database)` produce ONE function with THREE `_check` calls,
        // each at its own `#sourceLocation`. Dedup at the (key, type)
        // level; per-site attribution within the function.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty(
                    "primaryDB",
                    boundType: "Database",
                    key: "Database.primary",
                    line: 3,
                    sourcePath: "Wiring.swift"
                ),
                consumerWithKeyedDep(
                    "UserRepo",
                    depName: "db",
                    depType: "Database",
                    depKey: "Database.primary",
                    depLine: 5,
                    depSourcePath: "UserRepo.swift"
                ),
                consumerWithKeyedDep(
                    "Sessions",
                    depName: "db",
                    depType: "Database",
                    depKey: "Database.primary",
                    depLine: 9,
                    depSourcePath: "Sessions.swift"
                ),
            ]
        )
        // Exactly one function.
        #expect(output.contains("_wireTypeCheck_1()"))
        #expect(!output.contains("_wireTypeCheck_2"))
        // Three source-location anchors (one per site).
        let sourceLocOpenings = output.split(separator: "#sourceLocation(file:").count - 1
        #expect(sourceLocOpenings == 3)
        #expect(output.contains("\"Wiring.swift\", line: 3"))
        #expect(output.contains("\"UserRepo.swift\", line: 5"))
        #expect(output.contains("\"Sessions.swift\", line: 9"))
    }

    @Test func differentKeysProduceSeparateFunctions() {
        // Different keys on the same type → distinct check functions.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty(
                    "primaryDB",
                    boundType: "Database",
                    key: "Database.primary"
                ),
                keyedProperty(
                    "replicaDB",
                    boundType: "Database",
                    key: "Database.replica"
                ),
            ]
        )
        #expect(output.contains("_wireTypeCheck_1()"))
        #expect(output.contains("_wireTypeCheck_2()"))
        #expect(output.contains("_check(Database.primary, Database.self)"))
        #expect(output.contains("_check(Database.replica, Database.self)"))
    }

    @Test func differentTypesProduceSeparateFunctions() {
        // Same key text, different types → distinct check functions.
        // (Pathological in practice — keys are typed via `BindingKey<T>`
        // so `Database.primary` is `BindingKey<Database>`. This test
        // pins the discrimination behaviour regardless.)
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty("a", boundType: "Database", key: "shared"),
                keyedProperty("b", boundType: "Cache", key: "shared"),
            ]
        )
        #expect(output.contains("_wireTypeCheck_1()"))
        #expect(output.contains("_wireTypeCheck_2()"))
    }

    @Test func anyProtocolBindingsAreSkipped() {
        // `any P` existentials can't satisfy the generic helper's
        // `T == T` unification cleanly, so we skip emission. Mismatches
        // at these sites fall back to the build plugin's missing-
        // binding diagnostic at codegen.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty(
                    "fancyLogger",
                    boundType: "any Logger",
                    key: "Logger.fancy"
                )
            ]
        )
        #expect(!output.contains("_wireTypeCheck_"))
    }

    @Test func someProtocolBindingsAreSkipped() {
        // Same treatment for opaque types — concrete `T` unification
        // isn't available at the build-plugin level.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                consumerWithKeyedDep(
                    "Consumer",
                    depName: "log",
                    depType: "some Logger",
                    depKey: "Logger.fancy"
                )
            ]
        )
        #expect(!output.contains("_wireTypeCheck_"))
    }

    @Test func keyedProviderInGraphGetsKeyedAccessorName() {
        // A keyed `@Provides Database` paired with the unkeyed
        // `Database`-typed binding has to get a distinct identifier
        // for both the stored property on `_WireGraph` and the local
        // in `_wireBootstrap()`. `identifierName(forType:key:)` inserts
        // a `Keyed` infix between the type-derived prefix and the
        // sanitised key suffix — verbose but unambiguous, and the
        // sentinel infix keeps unkeyed type-named bindings safe from
        // collision. The integration test exercises this end-to-end
        // through the real build plugin; this unit test pins the
        // contract in-process where it counts toward coverage.
        let keyedDB: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Database",
                accessPath: "primaryDB",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("DB.swift"),
                keyIdentifier: "Database.primary",
                originModule: testModule
            )
        )
        let unkeyedDB: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Database",
                accessPath: "defaultDB",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("DB.swift"),
                keyIdentifier: nil,
                originModule: testModule
            )
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [unkeyedDB, keyedDB]
        )
        // Both accessors present, named for their identity.
        #expect(output.contains("let database: Database"))
        #expect(output.contains("let databaseKeyedDatabasePrimary: Database"))
        // Construction locals match the accessor names. RHS is the
        // provider's accessPath, which differs from the identifier.
        #expect(output.contains("let database = defaultDB"))
        #expect(output.contains("let databaseKeyedDatabasePrimary = primaryDB"))
    }

    @Test func keyedBindingWithDottedKeyCapitalizesEachSegment() {
        // Multi-segment key (`Module.shared.primary`) on a binding
        // whose type doesn't match the leading segment — so the
        // prefix-strip in `identifierName` is a no-op and the full
        // dotted text reaches `sanitizeKeyComponents`. Each dot
        // becomes a segment boundary: dropped, with the next letter
        // upper-cased. Composed suffix is `ModuleSharedPrimary`,
        // appended to the type-derived prefix.
        let exotic: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Database",
                accessPath: "exoticDB",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("DB.swift"),
                keyIdentifier: "Module.shared.primary",
                originModule: testModule
            )
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [exotic]
        )
        #expect(output.contains("let databaseKeyedModuleSharedPrimary: Database"))
    }

    @Test func keyedBindingWithBareKeyAppendsCapitalizedSuffix() {
        // A bare (non-type-qualified) key — `let alternate =
        // BindingKey<...>()` at file scope, referenced as
        // `@Provides(alternate)`. The key text doesn't have a leading
        // `<type>.` to strip, so the suffix is the upper-camelled key
        // appended verbatim. Exercises the path where the
        // `effectiveKey == key` after no-op prefix-strip.
        let alternateDB: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Database",
                accessPath: "altDB",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("DB.swift"),
                keyIdentifier: "alternate",
                originModule: testModule
            )
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [alternateDB]
        )
        #expect(output.contains("let databaseKeyedAlternate: Database"))
    }

    @Test func keyedDependencyResolvesToKeyedLocalName() {
        // A consumer with a keyed `@Inject` dep must resolve to the
        // keyed local name in the construction call — otherwise it'd
        // bind to whatever happens to be at the unkeyed slot. This
        // pins the `renderArguments` path through
        // `identifierName(forType:key:)`.
        let keyedDB: DiscoveredBinding = .provider(
            DiscoveredProvider(
                boundType: "Database",
                accessPath: "primaryDB",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("DB.swift"),
                keyIdentifier: "Database.primary",
                originModule: testModule
            )
        )
        let consumer: DiscoveredBinding = .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "UserRepo",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "db",
                        type: "Database",
                        kind: .injectProperty,
                        location: mockLocation("UserRepo.swift"),
                        keyIdentifier: "Database.primary"
                    )
                ],
                location: mockLocation("UserRepo.swift"),
                originModule: testModule
            )
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [keyedDB, consumer]
        )
        // Argument value uses the keyed local name, not the bare
        // `database` (which doesn't exist in this graph anyway).
        #expect(output.contains("let userRepo = UserRepo(db: databaseKeyedDatabasePrimary)"))
    }

    @Test func keyChecksSameFileSitesSortByLineWithinFunction() {
        // Two sites for the same `(key, type)` pair in the same file
        // but different lines. `locationOrder`'s line fallback orders
        // them ascending, so the lower-line `#sourceLocation` is
        // emitted first inside the dedup'd function body.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty(
                    "primaryDB",
                    boundType: "Database",
                    key: "Database.primary",
                    line: 9,
                    sourcePath: "App.swift"
                ),
                consumerWithKeyedDep(
                    "UserRepo",
                    depName: "db",
                    depType: "Database",
                    depKey: "Database.primary",
                    depLine: 3,
                    depSourcePath: "App.swift"
                ),
            ]
        )
        // One function (dedup'd), three #sourceLocation lines total
        // (open at line 3, close, open at line 9, close, plus the
        // final close). The line-3 opening comes before line-9.
        let line3 = output.firstRange(of: "\"App.swift\", line: 3")
        let line9 = output.firstRange(of: "\"App.swift\", line: 9")
        #expect(line3 != nil)
        #expect(line9 != nil)
        if let line3, let line9 {
            #expect(line3.lowerBound < line9.lowerBound)
        }
    }

    @Test func keyChecksSameFileAndLineSitesSortByColumn() {
        // Two sites with identical file and line but different
        // columns — the column-fallback branch of `locationOrder`.
        // Rare in practice (two annotations on the same line) but
        // pins the comparator's tail.
        let output = renderWireKeyChecks(
            imports: [],
            allBindings: [
                keyedProperty(
                    "primaryDB",
                    boundType: "Database",
                    key: "Database.primary",
                    line: 5,
                    column: 20,
                    sourcePath: "App.swift"
                ),
                consumerWithKeyedDep(
                    "UserRepo",
                    depName: "db",
                    depType: "Database",
                    depKey: "Database.primary",
                    depLine: 5,
                    depColumn: 5,
                    depSourcePath: "App.swift"
                ),
            ]
        )
        // The renderer doesn't emit the column in the `#sourceLocation`
        // directive (Swift's directive supports `file:` and `line:`
        // only), so we can't compare on column directly in the output.
        // Instead, check that both sites contributed `_check` calls in
        // a single function — both sites are deduped to the same
        // `(key, type)` pair so they share the function body. The
        // sort uses column to order them deterministically.
        let sourceLocOpenings = output.split(separator: "#sourceLocation(file:").count - 1
        #expect(sourceLocOpenings == 2)
    }

    @Test func keyChecksImportsAreEmittedSortedAndDeduplicated() {
        // Mirrors the renderWireGraph contract — duplicate imports are
        // collapsed, output is alphabetical for determinism.
        let output = renderWireKeyChecks(
            imports: ["import Wire", "import Foundation", "import Wire"],
            allBindings: []
        )
        let lineStrings = output.split(separator: "\n").map(String.init)
        let foundationIdx = lineStrings.firstIndex(of: "import Foundation")
        let wireIdx = lineStrings.firstIndex(of: "import Wire")
        #expect(foundationIdx != nil)
        #expect(wireIdx != nil)
        if let foundationIdx, let wireIdx {
            #expect(foundationIdx < wireIdx)
        }
        // Dedup: only one `import Wire` line.
        let wireOccurrences = lineStrings.filter { $0 == "import Wire" }.count
        #expect(wireOccurrences == 1)
    }

    // MARK: - Opaque lifting

    @Test func opaqueBindingsLiftGenericParametersOntoWireGraph() {
        // The task-cluster chain: a `some P` leaf feeds two `@Singleton(as:)`
        // lift nodes. Each opaque binding lifts a top-level generic parameter;
        // the bootstrap builds concretely and the structural opaque return type
        // binds the values. A constrained-parameter dependency (`table: Table`)
        // references the lifted local of its `some P` producer.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph<T0: DBTable & Sendable, T1: TaskRepo, T2: API> {
                let someDBTableSendable: T0
                let someTaskRepo: T1
                let someAPI: T2
            }

            private func _wireBootstrap() async throws -> _WireGraph<some DBTable & Sendable, some TaskRepo, some API> {
                let someDBTableSendable = Wiring.table
                let someTaskRepo = DynamoRepo(table: someDBTableSendable)
                let someAPI = Controller(repository: someTaskRepo)
                return _WireGraph(someDBTableSendable: someDBTableSendable, someTaskRepo: someTaskRepo, someAPI: someAPI)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph<some DBTable & Sendable, some TaskRepo, some API> {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty("Wiring.table", boundType: "some DBTable & Sendable"),
                liftNode(
                    "DynamoRepo",
                    identity: "TaskRepo",
                    parameter: "Table",
                    constraint: "DBTable & Sendable",
                    depName: "table"
                ),
                liftNode(
                    "Controller",
                    identity: "API",
                    parameter: "Repository",
                    constraint: "TaskRepo",
                    depName: "repository"
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func structuralLiftNodeReusesBridgeTargetParameterAsNestedField() {
        // Lift the minimum: the leaf and the `@Singleton(as:)` repo are bridge
        // targets, so each lifts a parameter (`T0`, `T1`). The controller — a
        // plain `@Singleton Controller<Repository: TaskRepo>`, read off the graph
        // — lifts *none*; it keeps its real type as a nested `Controller<T1>`
        // field (identity `Controller<some TaskRepo>`), reusing the repo's
        // parameter. So a two-parameter graph carries a three-node chain.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph<T0: DBTable & Sendable, T1: TaskRepo> {
                let someDBTableSendable: T0
                let someTaskRepo: T1
                let controllerOfsomeTaskRepo: Controller<T1>
            }

            private func _wireBootstrap() async throws -> _WireGraph<some DBTable & Sendable, some TaskRepo> {
                let someDBTableSendable = Wiring.table
                let someTaskRepo = DynamoRepo(table: someDBTableSendable)
                let controllerOfsomeTaskRepo = Controller(repository: someTaskRepo)
                return _WireGraph(someDBTableSendable: someDBTableSendable, someTaskRepo: someTaskRepo, controllerOfsomeTaskRepo: controllerOfsomeTaskRepo)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph<some DBTable & Sendable, some TaskRepo> {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty("Wiring.table", boundType: "some DBTable & Sendable"),
                liftNode(
                    "DynamoRepo",
                    identity: "TaskRepo",
                    parameter: "Table",
                    constraint: "DBTable & Sendable",
                    depName: "table"
                ),
                structuralLiftNode(
                    "Controller",
                    parameter: "Repository",
                    constraint: "TaskRepo",
                    depName: "repository"
                ),
            ]
        )
        #expect(output == expected)
    }

    @Test func multiParamStructuralLiftNodeSubstitutesEachParameterIndependently() {
        // A two-parameter structural node `Pair<Repository: TaskRepo, Log:
        // Logger>` reuses *two distinct* bridge-target parameters — each generic
        // parameter maps to its own constraint's lifted parameter, in order:
        // `Pair<T0, T1>`, not `Pair<T0, T0>` or a swapped pair.
        let expected = """
            // Generated by WireGen — do not edit.

            internal struct _WireGraph<T0: TaskRepo, T1: Logger> {
                let someTaskRepo: T0
                let someLogger: T1
                let pairOfsomeTaskRepoAndsomeLogger: Pair<T0, T1>
            }

            private func _wireBootstrap() async throws -> _WireGraph<some TaskRepo, some Logger> {
                let someTaskRepo = Wiring.repo
                let someLogger = Wiring.log
                let pairOfsomeTaskRepoAndsomeLogger = Pair(repository: someTaskRepo, log: someLogger)
                return _WireGraph(someTaskRepo: someTaskRepo, someLogger: someLogger, pairOfsomeTaskRepoAndsomeLogger: pairOfsomeTaskRepoAndsomeLogger)
            }

            internal enum _Wire {
                static func bootstrap() async throws -> _WireGraph<some TaskRepo, some Logger> {
                    try await _wireBootstrap()
                }
            }

            """
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty("Wiring.repo", boundType: "some TaskRepo"),
                providerProperty("Wiring.log", boundType: "some Logger"),
                .scopeBound(
                    DiscoveredScopeBoundType(
                        typeName: "Pair",
                        typeKind: "struct",
                        genericParameterNames: ["Repository", "Log"],
                        genericParameterConstraints: ["Repository": "TaskRepo", "Log": "Logger"],
                        dependencies: [
                            DependencyParameter(
                                name: "repository",
                                type: "Repository",
                                kind: .injectInitParameter,
                                location: mockLocation("Pair.swift")
                            ),
                            DependencyParameter(
                                name: "log",
                                type: "Log",
                                kind: .injectInitParameter,
                                location: mockLocation("Pair.swift")
                            ),
                        ],
                        location: mockLocation("Pair.swift"),
                        originModule: testModule
                    )
                ),
            ]
        )
        #expect(output == expected)
    }
}
