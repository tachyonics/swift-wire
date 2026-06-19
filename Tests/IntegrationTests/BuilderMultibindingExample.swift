import Wire

/// End-to-end exercise of `BuilderKey` multibindings across three result
/// shapes — a concrete type (`Pipeline`), a collection (`[any Middleware]`),
/// and an existential (`any Middleware`). The same two contributors fan
/// into all three via repeated `@Contributes`, which also exercises
/// multiple-keys-per-contributor end-to-end.
///
/// What this proves: WireGen reads each builder's result type from
/// `buildBlock` and emits a `@resultBuilder`-annotated fold whose explicit
/// return type compiles — including the existential case, where the result
/// type string carries an `any ` prefix.

protocol Middleware {
    var step: String { get }
}

struct Pipeline {
    let steps: [String]
}

struct CompositeMiddleware: Middleware {
    let parts: [String]
    var step: String { parts.joined(separator: ">") }
}

@resultBuilder
enum PipelineBuilder {
    static func buildBlock(_ parts: any Middleware...) -> Pipeline {
        Pipeline(steps: parts.map(\.step))
    }
}

@resultBuilder
enum MiddlewareListBuilder {
    static func buildBlock(_ parts: any Middleware...) -> [any Middleware] {
        Array(parts)
    }
}

@resultBuilder
enum ComposedMiddlewareBuilder {
    static func buildBlock(_ parts: any Middleware...) -> any Middleware {
        CompositeMiddleware(parts: parts.map(\.step))
    }
}

enum MiddlewareRegistry {
    static let pipeline = BuilderKey<PipelineBuilder>()  // concrete result
    static let list = BuilderKey<MiddlewareListBuilder>()  // collection result
    static let composed = BuilderKey<ComposedMiddlewareBuilder>()  // existential result
}

// Declared logging-first, but withOrder puts auth first in every fold.
@Singleton
@Contributes(to: MiddlewareRegistry.pipeline, withOrder: 2)
@Contributes(to: MiddlewareRegistry.list, withOrder: 2)
@Contributes(to: MiddlewareRegistry.composed, withOrder: 2)
struct LoggingMiddleware: Middleware {
    let step = "log"
}

@Singleton
@Contributes(to: MiddlewareRegistry.pipeline, withOrder: 1)
@Contributes(to: MiddlewareRegistry.list, withOrder: 1)
@Contributes(to: MiddlewareRegistry.composed, withOrder: 1)
struct AuthMiddleware: Middleware {
    let step = "auth"
}

@Singleton
struct MiddlewareHost {
    @Inject(MiddlewareRegistry.pipeline) var pipeline: Pipeline
    @Inject(MiddlewareRegistry.list) var list: [any Middleware]
    @Inject(MiddlewareRegistry.composed) var composed: any Middleware
}
