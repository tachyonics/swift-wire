import Wire

/// End-to-end exercise of a `BuilderKey` multibinding: contributors are
/// folded through a `@resultBuilder` into the builder's result type, which
/// the consumer `@Inject`s.
///
/// What this proves over the unit tests: WireGen reads the result type
/// from `buildBlock` (here `Pipeline`, a concrete type — not a collection),
/// and the generated bootstrap emits a `@MiddlewarePipeline`-annotated
/// fold function that actually compiles and runs, with `withOrder:`
/// driving the fold sequence.

protocol Middleware {
    var step: String { get }
}

struct Pipeline {
    let steps: [String]
}

@resultBuilder
enum MiddlewarePipeline {
    static func buildBlock(_ parts: any Middleware...) -> Pipeline {
        Pipeline(steps: parts.map(\.step))
    }
}

enum MiddlewareRegistry {
    static let pipeline = BuilderKey<MiddlewarePipeline>()
}

// Declared auth-second, but withOrder puts it first in the fold.
@Singleton @Contributes(to: MiddlewareRegistry.pipeline, withOrder: 2)
struct LoggingMiddleware: Middleware {
    let step = "log"
}

@Singleton @Contributes(to: MiddlewareRegistry.pipeline, withOrder: 1)
struct AuthMiddleware: Middleware {
    let step = "auth"
}

@Singleton
struct MiddlewareHost {
    @Inject(MiddlewareRegistry.pipeline) var pipeline: Pipeline
}
