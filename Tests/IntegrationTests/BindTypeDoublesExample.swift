import Synchronization
import Wire

/// M6a Phase 1 runtime fixture — a `@BindType` doubles substitution reaching a dependency *inside a seed
/// scope* (the no-cascade case). A `@Scoped(seed:)` controller injects `any TodoRepository`; the production
/// binding is `RealTodoRepository`, and the `TestingKey` binds that slot to `MockTodoRepository`, sourced
/// per scope-entry from a test-held `doubles`. WireGen emits a variant seed scope (disambiguated from the
/// production scope by the key) whose `bootstrap(seed:wireGraph:doubles:)` threads the doubles alongside
/// the seed, plus the `_<Key>Doubles` struct the test constructs. `BindTypeDoublesTests` proves the
/// controller resolves to the exact supplied instance.

/// Seed value for the test scope — carries an id the controller reads back.
struct TodoRequestSeed: Sendable {
    let id: String
}

/// The slot under test. Existential so producer and consumer match directly (no opaque-lift), keeping the
/// fixture focused on the doubles thread.
protocol TodoRepository: Sendable {
    func fetch(_ id: String) -> String
}

/// The production binding Wire constructs — replaced by `MockTodoRepository` under the `TestingKey`.
final class RealTodoRepository: TodoRepository {
    func fetch(_ id: String) -> String { "real:\(id)" }
}

/// A test-held mock recording every call, so the assertion can prove the *exact* supplied instance flows
/// through the generated scope-entry (reference identity via the recorded calls it mutates).
final class MockTodoRepository: TodoRepository {
    private let calls = Mutex<[String]>([])

    func fetch(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedFetches: [String] { calls.withLock { $0 } }
}

/// The real repository binding, scoped to the seed — so the mocked slot is reached inside a seed scope.
@Scoped(seed: TodoRequestSeed.self)
enum TodoRepositoryProvider {
    @Provides static func repository() -> any TodoRepository { RealTodoRepository() }
}

/// The seed-scoped consumer of the slot under test.
@Scoped(seed: TodoRequestSeed.self, allowUnused: true)
struct TodoController {
    @Inject var repository: any TodoRepository
    @Inject var todoRequestSeed: TodoRequestSeed

    func handle() -> String { repository.fetch(todoRequestSeed.id) }
}

/// The test-graph variant: bind the `TodoRepository` slot to `MockTodoRepository` for a scope entered with
/// this key's doubles.
enum WireDoublesFixture {
    @BindType(TodoRepository.self, MockTodoRepository.self)
    static let bindMockRepo = TestingKey()
}
