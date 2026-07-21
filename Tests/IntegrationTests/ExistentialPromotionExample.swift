import Wire

/// End-to-end fixture for rule 3 — a `some P` producer read by `any P`
/// consumers. The producer keeps its opaque identity (no boxing for a consumer
/// that bridges to it), while the two consumers here deliberately choose the
/// existential. Codegen binds one *existential alias* local — `let anyGreeting:
/// any Greeting = someGreeting` — so the value boxes once for both rather than
/// converting at each argument site. See `OpaqueTypesSupport.md`, rule 3.
///
/// Compiling this file at all is the point: the alias has to type-check against
/// the lifted `some Greeting` graph parameter.
protocol Greeting: Sendable {
    func greet() -> String
}

struct EnglishGreeting: Greeting {
    let subject: String

    func greet() -> String { "Hello, \(subject)!" }
}

@Provides
var greeting: some Greeting { EnglishGreeting(subject: "world") }

@Singleton(allowUnused: true)
struct GreetingReporter {
    @Inject var greeting: any Greeting

    func report() -> String { greeting.greet() }
}

@Singleton(allowUnused: true)
struct GreetingAuditor {
    @Inject var greeting: any Greeting

    func audit() -> Int { greeting.greet().count }
}
