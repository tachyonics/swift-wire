import Synchronization

/// A Sendable coordination primitive that holds a value which is
/// computed at most once, with a tri-state lifecycle: unmarked
/// (nothing has tried to compute yet) → pending (one caller is
/// committed to computing) → resolved (the value is available).
///
/// `AtomicState<Value>` is used as the building block for "first-
/// caller wins, subsequent callers see the cached value" patterns:
///
/// - **`Lazy<T>`** (iteration 4b): wraps a deferred construction
///   factory. The first `get()` call CAS's pending and runs the
///   factory; concurrent first-callers see pending and await the
///   same `Task<T, Error>`.
/// - **Per-binding parallel-resolution codegen** (deferred to Wire's
///   Level 2 implementation): each binding in a parallel graph
///   gets its own `AtomicState<T>`. Per-binding `addX()` closures
///   CAS pending, run construction (possibly in a child `Task`),
///   set resolved, and trigger dependents — whose dep checks read
///   each other's `AtomicState` to decide whether to fire.
///
/// The type is `final class` (reference semantics) because each
/// coordination cell is shared across multiple closures and Tasks
/// — copying value-type semantics would defeat the "single cell
/// of state" purpose. `@unchecked Sendable` because we manage the
/// internal `Mutex` manually; the compiler can't verify the
/// non-`Copyable` Mutex's encapsulation by inspection alone but
/// the `Mutex<State>` discipline is correct by construction.
///
/// Error semantics: if a caller commits to computing (via
/// `asPending()` returning true) and then fails to call
/// `asResolved(_:)` (e.g., the construction throws), the state
/// stays at `pending` indefinitely. Dependents reading the state
/// will see `pending` and short-circuit. This isn't a leak in
/// practice — error propagation through structured concurrency
/// (`TaskGroup` cancellation) tears down the enclosing scope
/// before any dependent's read could matter. For non-structured-
/// concurrency use cases (e.g., `Lazy<T>` with no group around
/// it), the failure is encoded in the `Task<T, Error>` the Lazy
/// wraps; subsequent `Lazy.get()` calls rethrow the same error.
/// `AtomicState` itself isn't responsible for error caching.
public final class AtomicState<Value: Sendable>: @unchecked Sendable {
    /// The lifecycle states of an `AtomicState`.
    public enum State: Sendable {
        /// Nothing has tried to compute the value yet. Available
        /// for the first `asPending()` caller to claim.
        case unmarked
        /// A caller has claimed the right to compute (via a
        /// successful `asPending()`) but hasn't called
        /// `asResolved(_:)` yet. Other callers' `asPending()` will
        /// return false; dep-checking readers will see `pending`
        /// and short-circuit.
        case pending
        /// The value has been computed and is available.
        /// `asPending()` returns false; `asResolved(_:)` becomes a
        /// no-op (the first resolution wins).
        case resolved(Value)
    }

    private let storage = Mutex<State>(.unmarked)

    public init() {}

    /// Atomically transition `unmarked` → `pending`. Returns
    /// `true` when the caller successfully claimed the right to
    /// compute the value (the state was `unmarked` and is now
    /// `pending`). Returns `false` when the state was already
    /// `pending` or `resolved` — duplicate callers short-circuit
    /// without redundant work.
    ///
    /// This is the CAS at the heart of "first caller wins"
    /// patterns. The caller that gets `true` is responsible for
    /// eventually calling `asResolved(_:)` with the computed
    /// value.
    public func asPending() -> Bool {
        storage.withLock { state in
            guard case .unmarked = state else { return false }
            state = .pending
            return true
        }
    }

    /// Transition to `resolved` with the provided value. The first
    /// call wins; subsequent calls are silently ignored (so
    /// repeated resolution attempts don't clobber the cached
    /// value).
    public func asResolved(_ value: Value) {
        storage.withLock { state in
            if case .resolved = state { return }
            state = .resolved(value)
        }
    }

    /// Snapshot the current state. The returned value is a
    /// point-in-time copy; concurrent callers may observe later
    /// transitions on subsequent calls. Pattern-match against the
    /// returned `State` to inspect.
    public func read() -> State {
        storage.withLock { $0 }
    }
}
