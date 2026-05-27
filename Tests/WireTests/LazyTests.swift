import Testing

@testable import Wire

@Suite("Lazy")
struct LazyTests {
    // MARK: - Basic semantics

    @Test func factoryNotCalledUntilGet() async throws {
        // Lazy's factory must not run until the first get() call —
        // the entire point of the wrapper is deferral.
        let callCount = CallCount()
        let lazy = Lazy<Int> {
            await callCount.increment()
            return 42
        }
        #expect(await callCount.value == 0)
        let value = try await lazy.get()
        #expect(value == 42)
        #expect(await callCount.value == 1)
    }

    @Test func factoryCalledOnceAcrossSequentialGets() async throws {
        // First get runs the factory; subsequent gets return the
        // cached value without re-running it.
        let callCount = CallCount()
        let lazy = Lazy<String> {
            await callCount.increment()
            return "computed"
        }
        let first = try await lazy.get()
        let second = try await lazy.get()
        let third = try await lazy.get()
        #expect(first == "computed")
        #expect(second == "computed")
        #expect(third == "computed")
        #expect(await callCount.value == 1)
    }

    @Test func factoryCalledOnceAcrossConcurrentFirstCallers() async throws {
        // 100 concurrent first-callers should all see the same
        // value, with the factory invoked exactly once. The
        // Tri-state Mutex<State> coordination is the central
        // correctness invariant — this hammers it.
        let callCount = CallCount()
        let lazy = Lazy<Int> {
            await callCount.increment()
            // Yield to maximise the race window — every concurrent
            // caller should see the partially-initialised state.
            await Task.yield()
            return 99
        }
        let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    (try? await lazy.get()) ?? -1
                }
            }
            var collected: [Int] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(results.allSatisfy { $0 == 99 })
        #expect(results.count == 100)
        #expect(await callCount.value == 1)
    }

    // MARK: - Failure caching

    @Test func factoryFailureRethrowsOnFirstGet() async {
        let lazy = Lazy<Int> {
            throw TestError.boom
        }
        do {
            _ = try await lazy.get()
            Issue.record("expected get() to throw")
        } catch let error as TestError {
            #expect(error == .boom)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func factoryFailureCachedOnSubsequentGets() async {
        // Once the factory throws, every subsequent get() rethrows
        // the same error without re-running the factory. Matches
        // Kotlin's lazy { } and Dagger's Provider.get() semantics.
        let callCount = CallCount()
        let lazy = Lazy<Int> {
            await callCount.increment()
            throw TestError.boom
        }
        for _ in 0..<5 {
            do {
                _ = try await lazy.get()
                Issue.record("expected get() to throw on every call")
            } catch is TestError {
                // pass
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(await callCount.value == 1)
    }

    @Test func factoryFailureCachedAcrossConcurrentCallers() async {
        // Concurrent first-callers all see the same error from one
        // factory invocation — failure caching survives the same
        // race the happy path does.
        let callCount = CallCount()
        let lazy = Lazy<Int> {
            await callCount.increment()
            await Task.yield()
            throw TestError.boom
        }
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<50 {
                group.addTask {
                    do {
                        _ = try await lazy.get()
                        return false  // unexpected success
                    } catch is TestError {
                        return true
                    } catch {
                        return false  // unexpected error
                    }
                }
            }
            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(results.allSatisfy { $0 })
        #expect(await callCount.value == 1)
    }

    // MARK: - Sync-init compatibility (no-op await cost)

    @Test func syncFactoryWorksUnderAsyncContract() async throws {
        // The widest-contract design says async-throws `.get()`
        // accepts factories of any colour, including pure-sync.
        // This is the cost of the design — sync factories pay a
        // no-op await — but the value is real (forward compat with
        // factory colour changes).
        let lazy = Lazy<Int> { 7 }
        let value = try await lazy.get()
        #expect(value == 7)
    }

    // MARK: - Sharing semantics across copies

    @Test func copiedLazySharesCachedValue() async throws {
        // Lazy is a value type, but it boxes a class (LazyBox). Two
        // copies of the same Lazy share the same backing
        // coordination — calling get() on one and then on the
        // other observes the same cached value, with the factory
        // running once total.
        let callCount = CallCount()
        let lazy = Lazy<Int> {
            await callCount.increment()
            return 13
        }
        let copy = lazy
        let first = try await lazy.get()
        let second = try await copy.get()
        #expect(first == 13)
        #expect(second == 13)
        #expect(await callCount.value == 1)
    }
}

/// Async-safe counter for tracking factory invocations. An actor
/// would be over-engineered; this gets the cooperative-isolation
/// semantics tests need without needing a separate type per case.
private actor CallCount {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}

private enum TestError: Error, Equatable {
    case boom
}
