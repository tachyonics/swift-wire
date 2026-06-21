import Wire

/// Exercises effect-aware emission for user-written
/// `@Inject init() async throws` on a `@Singleton` type. Discovery
/// reads the init's effect specifiers via SwiftSyntax and tags the
/// `DiscoveredScopeBoundType` with `initIsAsync: true,
/// initIsThrowing: true`. Codegen emits
/// `let asyncInitConsumer = try await AsyncInitConsumer(...)` at
/// the construction site.
///
/// The init's body performs real async work (a scheduler yield) so
/// the `await` propagates a real suspension point through to the
/// bootstrap function's evaluation, not just a syntactic prefix
/// the compiler optimises out.
@Singleton(allowUnused: true)
package struct AsyncInitConsumer {
    package let token: AsyncToken
    package let message: AsyncMessage
    package let preparedAt: ContinuousClock.Instant

    @Inject
    package init(token: AsyncToken, message: AsyncMessage) async throws {
        try await Task.sleep(nanoseconds: 1)
        self.token = token
        self.message = message
        self.preparedAt = ContinuousClock.now
    }

    package func describe() -> String {
        "init received \(token.value) + \(message.payload)"
    }
}
