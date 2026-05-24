import Wire

/// Scope-bound type that reads both the seed (request scope's
/// identifier) and a singleton (the process-wide `Logger`). Exercises
/// the synthetic-seed alias and the singleton-borrow inline at one
/// consumer's call site.
@Scoped(seed: TestRequestSeed.self)
struct RequestLogger {
    @Inject var testRequestSeed: TestRequestSeed
    @Inject var logger: Logger

    func log(_ message: String) -> String {
        logger.log("[\(testRequestSeed.id)] \(message)")
    }
}
