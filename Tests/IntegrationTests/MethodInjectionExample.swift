import Wire

/// End-to-end exercise of `@Inject func` — the general post-
/// construction member injection form. The consumer writes a
/// method instead of an `@Inject weak var`, opting into post-
/// construct delivery for whatever reason (custom storage,
/// observability, deferred initialisation). Wire's contract is
/// "find `@Inject` methods, resolve their parameters from the
/// graph, call them after the consumer is constructed."
///
/// This fixture demonstrates a Sendable consumer wiring a strong
/// dep into its own state via a method — no `weak`, no
/// `@unchecked Sendable`. Method injection is genuinely Sendable
/// here because the storage (`appendedNote`) is mutable through
/// the method but accessed only after bootstrap completes.
@Singleton
package final class NoteBoard: @unchecked Sendable {
    /// State mutated by the `@Inject` method. Single-write,
    /// multi-read pattern that's safe by audit (the write happens
    /// during bootstrap, reads happen after).
    private var appendedNote: String = "uninitialised"

    @Inject
    package func receive(message: NoteMessage) {
        appendedNote = "wire said: \(message.payload)"
    }

    package func current() -> String {
        appendedNote
    }
}

package struct NoteMessage: Sendable {
    package let payload: String
}

@Provides
package let noteMessage: NoteMessage = NoteMessage(payload: "hello from @Inject func")
