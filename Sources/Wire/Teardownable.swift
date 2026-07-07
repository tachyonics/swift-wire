/// A generated graph that can tear down its resources. The build plugin conforms every
/// graph struct to this protocol so a facade (e.g. WireHummingbird's shutdown service)
/// can drive teardown via `some Teardownable` without naming the internal, concrete
/// `_WireGraph` — and can do so *unconditionally*, since every graph conforms.
///
/// `teardown()` calls each `@Teardown` action in reverse construction order. It
/// **collects** rather than throws: a failing action doesn't stop the ones after it, and
/// the returned errors are the caller's to log.
public protocol Teardownable {
    func teardown() async -> [any Error]
}

extension Teardownable {
    /// A graph with no `@Teardown` bindings has nothing to tear down. The plugin emits a
    /// real `teardown()` only when there's at least one action; otherwise this default
    /// applies, so the conformance stays universal without emitting an empty method on
    /// every graph.
    public func teardown() async -> [any Error] { [] }
}
