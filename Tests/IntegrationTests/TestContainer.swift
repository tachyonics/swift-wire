import Wire

/// Primary `@Container` declaration. Holds a `@Provides` and a nested
/// `@Singleton` to exercise both routing paths through to per-container
/// codegen. The container's `Banner` binding is a direct fixed value
/// — distinct from the default graph's `Banner` (composed via
/// `makeBanner(appName:, buildNumber:)`) — so the integration tests
/// can prove the two graphs are independent and atomic, even though
/// they bind the same type.
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
}
