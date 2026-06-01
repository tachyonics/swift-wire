import Synchronization

/// A deferred-construction wrapper for an intra-scope dependency
/// whose initialisation should run on first use, not at bootstrap
/// time. Consumers `@Inject` `Lazy<T>` instead of `T` to opt in;
/// the build plugin recognises the wrapper, defers `T`'s
/// construction inside the Lazy's factory closure, and emits the
/// wrapper at the consumer's slot.
///
///     @Singleton
///     struct Application {
///         @Inject var pool: Lazy<DatabasePool>
///
///         func handle(request: Request) async throws {
///             let db = try await pool.get()
///             // pool's construction runs on first call;
///             // subsequent calls return the cached value.
///         }
///     }
///
/// ## API shape
///
/// `get()` is `async throws` regardless of `T`'s init colour —
/// the widest-contract surface stays stable as `T`'s
/// implementation evolves. A sync-init `T` pays a no-op `await`
/// at the consumer site; an `async throws` `T` flows naturally.
/// Either way the consumer's call site doesn't change when
/// `T`'s init colour does. See
/// `Documentation/Notes/LazyTypeSupport.md` for the architectural
/// rationale (widest-contract = best port).
///
/// The naming `.get()` matches JVM idiom (`Dagger.Provider.get`,
/// `Java.Optional.get`, `Kotlin.Lazy.value`) and Swift's own
/// `Result.get()`.
///
/// ## Concurrency
///
/// `Lazy<T>` is `Sendable` when `T: Sendable` (which Wire requires
/// of all bindings). First-call coordination uses a tri-state
/// `Mutex<State>` inside the internal `LazyBox`
/// (`.unmarked(factory) → .pending(Task) → .resolved(Value)`):
/// the first caller in the lock moves the factory out of the
/// `.unmarked` case into a new `Task<T, Error>` and transitions
/// state to `.pending`; subsequent and concurrent first-callers
/// see the same Task and await its value. The Task writes
/// `.resolved(Value)` on success, so post-resolution gets read
/// the value directly without a Task hop and the Task's closure
/// capture (which held the factory and anything it captured) is
/// released. The box ends up holding only the cached `Value`,
/// not the closure-captured graph state the factory needed to
/// construct it. Exactly one factory invocation regardless of how
/// many concurrent callers race for the first `get()`.
///
/// Failure caching: if the factory throws, the state stays at
/// `.pending(task)`; subsequent `get()` calls await the same
/// cached Task and observe the same error rather than retrying.
/// Matches Kotlin's `lazy { }` and
/// Dagger's `Provider.get()` semantics.
///
/// ## Scope rules
///
/// `Lazy<T>` is intra-scope only — the deferred `T` is resolved
/// against the consumer's scope, not against a parent or sibling
/// scope. A `@Singleton`'s `Lazy<T>` resolves `T` from singletons;
/// a `@Scoped(seed: X.self)` type's `Lazy<T>` resolves `T` from
/// the X-scoped graph (plus borrowed singletons). Cross-scope
/// rules from iteration 4c apply to the unwrapped `T`; the
/// wrapper doesn't paper over partition mismatches.
public struct Lazy<Value: Sendable>: Sendable {
    private let box: LazyBox<Value>

    /// Construct a `Lazy<Value>` with a factory closure.
    /// The factory runs at most once, on the first `get()` call.
    /// The returned value is cached and shared with concurrent and
    /// subsequent callers.
    ///
    /// Normally Wire's build plugin synthesises the Lazy and its
    /// factory closure at the bootstrap call site; users rarely
    /// construct `Lazy<T>` directly. The initialiser is `public`
    /// to support the escape-hatch case where a `@Provides`
    /// declaration produces a `Lazy<T>` explicitly (e.g., to
    /// supply a custom factory with side effects). Per
    /// `LazyTypeSupport.md`, user-provided Lazy bindings bypass
    /// the no-effect-warning machinery — they're treated as
    /// regular `Lazy<T>` bindings.
    public init(_ factory: @escaping @Sendable () async throws -> Value) {
        self.box = LazyBox(factory: factory)
    }

    /// Return the wrapped value. On the first call, runs the
    /// factory; on subsequent calls (and concurrent ones), returns
    /// the cached value (or rethrows the cached error if the
    /// factory failed).
    public func get() async throws -> Value {
        try await box.get()
    }
}

/// Internal box class that owns the Mutex-guarded coordination
/// state. Class semantics (reference-type) so multiple
/// `Lazy<Value>` value-type wrappers can share the same
/// coordination state without copying the Mutex (which is
/// non-`Copyable` and thus can't live directly in a value type
/// that needs to be Sendable+shared).
///
/// `@unchecked Sendable` reflects manual encapsulation of the
/// non-`Copyable` `Mutex`; the compiler can't verify the storage
/// shape, but the Mutex discipline (single point of mutation
/// behind the lock) is correct by construction.
///
/// The state machine mirrors `AtomicState<T>`'s tri-state lifecycle
/// (unmarked → pending → resolved), adapted for Lazy's "create-or-
/// await" coordination needs. The factory closure is the
/// `.unmarked` case's associated value, so the box's storage holds
/// each input reference at most once across the state's lifetime:
///
/// - `.unmarked(factory)`: holds the factory closure. No caller has
///   triggered it yet.
/// - `.pending(Task)`: factory has been moved into the Task's
///   closure capture; the State no longer references the factory
///   directly. Concurrent callers see the same Task and await its
///   value. The Task writes back `.resolved` on success.
/// - `.resolved(Value)`: factory completed; the Task (and the
///   factory it captured) is released. Subsequent get() calls read
///   the value directly without a Task hop. The box holds only the
///   value.
///
/// Net effect: the LazyBox holds the factory's references on
/// exactly one path at a time — first via the `.unmarked` case,
/// then through the Task's capture in `.pending`, then released
/// entirely in `.resolved`. The successful-resolution path leaves
/// the box holding only the cached `Value`, not the closure-
/// captured graph state the factory needed to construct it.
///
/// Failure caching: a failed Task stays in `.pending(task)`
/// indefinitely — subsequent get() calls await the same Task and
/// observe the cached error. Adding a `.failed` state would need
/// `Sendable`-compatible error storage and complicates the state
/// machine for the rare path; the pending-with-failed-Task
/// approach is correct and simpler. Memory cost: the closure
/// capture is retained on failure; acceptable since failure is
/// the uncommon path.
private final class LazyBox<Value: Sendable>: @unchecked Sendable {
    enum State {
        case unmarked(@Sendable () async throws -> Value)
        case pending(Task<Value, Error>)
        case resolved(Value)
    }

    /// Result of the inside-lock decision: either the value is
    /// already cached (return directly) or there's a Task to
    /// await (potentially the one we just created). Hoisted to
    /// the class level because nested types can't live inside
    /// generic-class methods.
    private enum Outcome {
        case resolved(Value)
        case awaitTask(Task<Value, Error>)
    }

    private let mutex: Mutex<State>

    init(factory: @escaping @Sendable () async throws -> Value) {
        self.mutex = Mutex(.unmarked(factory))
    }

    func get() async throws -> Value {
        // Single lock acquisition handles all three cases:
        // - `.resolved`: return value directly (no Task hop).
        // - `.pending`: await the existing Task.
        // - `.unmarked`: move the factory into a new Task, transition
        //   the state to `.pending` (which now owns the Task; the
        //   factory's lifetime follows the Task's closure capture
        //   from this point).
        let outcome: Outcome = mutex.withLock { state in
            switch state {
            case .resolved(let value):
                return .resolved(value)
            case .pending(let existing):
                return .awaitTask(existing)
            case .unmarked(let factory):
                // First caller — move the factory from the State's
                // associated value into a new Task. Concurrent and
                // subsequent callers see this Task via `.pending`
                // until it completes; after the Task writes
                // `.resolved`, the fast path takes over and the
                // Task (and its captured factory) is released.
                let new = Task<Value, Error> {
                    let value = try await factory()
                    // Transition pending → resolved. The Task
                    // reference + closure capture become eligible
                    // for release once outstanding awaiters resume.
                    self.mutex.withLock { storedState in
                        storedState = .resolved(value)
                    }
                    return value
                }
                state = .pending(new)
                return .awaitTask(new)
            }
        }
        switch outcome {
        case .resolved(let value):
            return value
        case .awaitTask(let task):
            return try await task.value
        }
    }
}
