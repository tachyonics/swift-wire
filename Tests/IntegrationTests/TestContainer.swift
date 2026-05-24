import Wire

/// Seed value for a container-scoped seed. Lives at module scope
/// because Swift macros can't see nested types from the `@Scoped`
/// argument; the scope-bound type below references it via its
/// unqualified name.
struct TestJobSeed: Sendable {
    let queue: String
}

/// Primary `@Container` declaration. Holds a `@Provides`, a nested
/// `@Singleton`, and a nested `@Scoped(seed:)` to exercise both
/// singleton routing and per-container seeded-scope codegen. The
/// container's `Banner` binding is a direct fixed value — distinct
/// from the default graph's `Banner` (composed via
/// `makeBanner(appName:, buildNumber:)`) — so the integration tests
/// can prove the two graphs are independent and atomic, even though
/// they bind the same type. The nested `@Scoped` type proves the
/// `(container, seed)` partition cell generates a
/// `_TestContainer_TestJobSeedWireScope` that borrows from the
/// container's singletons (not the default graph's).
@Container
enum TestContainer {
    @Provides static let banner: Banner = Banner(text: "test container")

    @Singleton
    struct MockBannerService {
        @Inject var banner: Banner

        func display() -> String {
            "mock: \(banner.text)"
        }
    }

    @Scoped(seed: TestJobSeed.self)
    struct JobRunner {
        @Inject var testJobSeed: TestJobSeed
        @Inject var banner: Banner

        func run() -> String {
            "[\(testJobSeed.queue)] running on \(banner.text)"
        }
    }
}
