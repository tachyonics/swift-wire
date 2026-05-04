import Wire

/// Property-injection consumer. Exercises the "macro synthesises an
/// init from `@Inject` stored properties" path; the resulting init's
/// parameter list is what WireGen emits at the bootstrap call site.
@Singleton
struct UserRepository {
    @Inject var logger: Logger

    func describe() -> String {
        logger.log("UserRepository")
    }
}
