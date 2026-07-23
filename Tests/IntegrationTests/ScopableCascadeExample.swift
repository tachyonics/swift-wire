import Synchronization
import Wire

/// M6a Phase 2 runtime fixture — the `@Scopable` cascade reaching a `@BindType`d dependency through an
/// *app-scoped* consumer. A `@Singleton` controller reads `any AccountRepository` in its `init`; the
/// production binding is `RealAccountRepository`, an app-scoped `@Provides`. The `TestingKey` binds that
/// slot to `MockAccountRepository` and marks the controller `@Scopable`, so under test WireGen lifts both
/// the controller and the repository out of the app graph and into the seed scope — the controller is
/// reconstructed per scope entry, and its init-time read sees the per-entry double.
///
/// This is the distinguishing Phase-2 property over the per-call proxy alternative: a proxy would only mock
/// *per-call* reads, never the one at `init`. `ScopableCascadeTests` proves the reconstructed controller's
/// init-time read used the supplied mock.

/// Seed value for the test scope — establishes the seed the doubles ride, and carries an id.
struct AccountRequestSeed: Sendable {
    let id: String
}

/// The slot under test. Existential so producer and consumer match directly, keeping the fixture focused on
/// the cascade rather than the opaque-lift.
protocol AccountRepository: Sendable {
    func tag(_ id: String) -> String
}

/// The production binding — an app-scoped `@Provides`, replaced by `MockAccountRepository` under the key.
final class RealAccountRepository: AccountRepository {
    func tag(_ id: String) -> String { "real:\(id)" }
}

/// A test-held mock recording every call, so the assertion can prove the *exact* supplied instance flowed
/// through the reconstructed controller's `init`.
final class MockAccountRepository: AccountRepository {
    private let calls = Mutex<[String]>([])

    func tag(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    var recordedTags: [String] { calls.withLock { $0 } }
}

/// The `@BindType`d binding — an app-scoped (module-scope) `@Provides`.
enum AccountRepositoryModule {
    @Provides static func repository() -> any AccountRepository { RealAccountRepository() }
}

/// The app-scoped consumer that reads its `@BindType`d dependency **in `init`** — the property Phase 2
/// exists to mock. As a singleton it is built once at bootstrap in production; `@Scopable` lifts it into the
/// scope under test so this read sees the per-entry double.
@Singleton
final class AccountController {
    let tag: String

    @Inject init(repository: any AccountRepository) {
        self.tag = repository.tag("init")
    }
}

/// The `@Scoped(seed:)` root establishing the seed scope; injects the singleton controller so the cascade
/// has a seed root to lift toward.
@Scoped(seed: AccountRequestSeed.self, allowUnused: true)
struct AccountRequestController {
    @Inject var controller: AccountController
    @Inject var accountRequestSeed: AccountRequestSeed

    func handle() -> String { controller.tag }
}

/// The test-graph variant: bind the `AccountRepository` slot to `MockAccountRepository`, and permit the
/// cascade to lift the app-scoped `AccountController` into the scope entered with this key's doubles.
enum WireScopableFixture {
    @BindType(AccountRepository.self, MockAccountRepository.self)
    @Scopable(AccountController.self)
    static let bindMockRepo = TestingKey()
}
