import Wire

/// End-to-end exercise of `@Inject func` — the general post-
/// construction member injection form. The consumer writes a
/// method instead of an `@Inject weak var`, opting into post-
/// construct delivery for whatever reason (custom storage,
/// observability, deferred initialisation). Wire's contract is
/// "find `@Inject` methods, resolve their parameters from the
/// graph, call them after the consumer is constructed."
///
/// This fixture is honestly non-Sendable — `appendedNote` is
/// mutable storage on a class, no synchronisation. The fixture
/// works because the test holds the graph in a single task and
/// never crosses an isolation boundary. The generated `_WireGraph`
/// is non-Sendable too (auto-derived from the binding profile),
/// which is exactly the trade-off auto-derived `Sendable`
/// surfaces at the right layer: the user's binding profile
/// dictates the graph's conformance, not a hardcoded annotation
/// from Wire.
@Singleton(allowUnused: true)
package final class NoteBoard {
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
