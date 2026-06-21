import Wire

/// End-to-end exercise of `@Inject func` on an `actor` host type —
/// the canonical "checked-Sendable post-init delivery" pattern.
/// Actors are inherently `Sendable`, so the consumer can sit in
/// `_WireGraph: Sendable` graphs without any `@unchecked` opt-in.
/// Wire's codegen knows the consumer is an actor and emits
/// `await counter.bump(by: ...)` for the method-injection call,
/// even though `bump(by:)` itself isn't declared `async` — the
/// `await` is paying for the isolation crossing from the
/// (non-isolated) bootstrap function into the actor's domain.
@Singleton(allowUnused: true)
package actor TickCounter {
    private(set) package var ticks: Int = 0

    @Inject
    package func bump(by amount: TickIncrement) {
        ticks += amount.value
    }
}

package struct TickIncrement: Sendable {
    package let value: Int
}

@Provides
package let tickIncrement: TickIncrement = TickIncrement(value: 7)
