import Testing

@testable import Wire

@Suite("AtomicState")
struct AtomicStateTests {
    // MARK: - Single-threaded state transitions

    @Test func startsUnmarked() {
        let state = AtomicState<Int>()
        if case .unmarked = state.read() {
            // pass
        } else {
            Issue.record("expected initial state to be .unmarked")
        }
    }

    @Test func firstAsPendingSucceeds() {
        let state = AtomicState<Int>()
        #expect(state.asPending() == true)
        if case .pending = state.read() {
            // pass
        } else {
            Issue.record("expected state to be .pending after asPending()")
        }
    }

    @Test func secondAsPendingFails() {
        let state = AtomicState<Int>()
        #expect(state.asPending() == true)
        #expect(state.asPending() == false)
    }

    @Test func asResolvedTransitionsState() {
        let state = AtomicState<Int>()
        _ = state.asPending()
        state.asResolved(42)
        if case .resolved(let value) = state.read() {
            #expect(value == 42)
        } else {
            Issue.record("expected state to be .resolved after asResolved(_:)")
        }
    }

    @Test func asPendingAfterResolvedFails() {
        // Once resolved, the state can't be reclaimed for pending —
        // the value is sticky.
        let state = AtomicState<Int>()
        _ = state.asPending()
        state.asResolved(42)
        #expect(state.asPending() == false)
    }

    @Test func secondAsResolvedIsIgnored() {
        // First resolution wins; subsequent calls don't clobber the
        // cached value. Guards against racing resolvers overwriting
        // each other's results.
        let state = AtomicState<Int>()
        _ = state.asPending()
        state.asResolved(42)
        state.asResolved(99)
        if case .resolved(let value) = state.read() {
            #expect(value == 42)
        } else {
            Issue.record("expected state to remain .resolved with first value")
        }
    }

    @Test func asResolvedWithoutPendingStillWorks() {
        // The asPending() CAS is a coordination hint, not a hard
        // gate. Callers that don't bother with asPending() can still
        // call asResolved(_:) directly — useful for sync codegen
        // paths where there's no race to coordinate.
        let state = AtomicState<Int>()
        state.asResolved(42)
        if case .resolved(let value) = state.read() {
            #expect(value == 42)
        } else {
            Issue.record("expected direct asResolved() to set state")
        }
    }

    // MARK: - Concurrent stress

    @Test func concurrentAsPendingExactlyOneWinner() async {
        // 100 concurrent asPending() calls — exactly one should win
        // (return true) and the rest should fail (return false). The
        // CAS is the central correctness invariant; this hammers it.
        let state = AtomicState<Int>()
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask { state.asPending() }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        let winners = outcomes.filter { $0 }.count
        let losers = outcomes.filter { !$0 }.count
        #expect(winners == 1)
        #expect(losers == 99)
    }

    @Test func concurrentAsResolvedFirstValueWins() async {
        // Multiple concurrent asResolved() calls — exactly one of
        // them sticks (the first one to acquire the lock). Subsequent
        // calls are no-ops. The test asserts SOME value sticks (we
        // can't predict which due to scheduling) and that the
        // observed value is one of the offered ones.
        let state = AtomicState<Int>()
        let offered = (0..<100).map { $0 }
        await withTaskGroup(of: Void.self) { group in
            for value in offered {
                group.addTask { state.asResolved(value) }
            }
            for await _ in group {}
        }
        guard case .resolved(let final) = state.read() else {
            Issue.record("expected state to be .resolved after concurrent writers")
            return
        }
        #expect(offered.contains(final))
    }

    @Test func concurrentReadDuringTransitionsObservesValidStates() async {
        // While one task transitions unmarked → pending → resolved,
        // a concurrent reader should only ever see valid states (no
        // torn reads). With Mutex-guarded access, every read returns
        // a self-consistent snapshot.
        let state = AtomicState<Int>()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = state.asPending()
                state.asResolved(42)
            }
            for _ in 0..<50 {
                group.addTask {
                    // Repeatedly read while the writer transitions.
                    // Each read must return one of the known states;
                    // if a torn read occurred we'd see an invalid
                    // case (which Swift's enum type system makes
                    // impossible to construct, so this assertion is
                    // really exercising the Mutex correctness).
                    for _ in 0..<100 {
                        let snapshot = state.read()
                        switch snapshot {
                        case .unmarked, .pending, .resolved:
                            break  // any valid state is fine
                        }
                    }
                }
            }
            for await _ in group {}
        }
        // Final state must be resolved (the writer ran to completion).
        if case .resolved(let value) = state.read() {
            #expect(value == 42)
        } else {
            Issue.record("expected final state to be .resolved")
        }
    }

    // MARK: - Sendable + reference semantics

    @Test func sharedReferenceSeesUpdatesAcrossTasks() async {
        // AtomicState is a class — two references to the same
        // instance see the same state. The reference-semantics
        // property is what lets per-binding closures share
        // coordination state.
        let state = AtomicState<String>()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = state.asPending()
                state.asResolved("hello")
            }
            group.addTask {
                // Spin until resolved. Cooperative — relies on
                // Mutex correctness for the visibility guarantee.
                while case .unmarked = state.read() {
                    await Task.yield()
                }
                while case .pending = state.read() {
                    await Task.yield()
                }
                guard case .resolved(let value) = state.read() else {
                    Issue.record("expected resolved state in observer task")
                    return
                }
                #expect(value == "hello")
            }
            for await _ in group {}
        }
    }
}
