// MARK: - Classification

/// Identity used to group `Lazy<T>` consumer-classification results.
/// Mirrors the graph's `BindingIdentity` shape — canonicalised type
/// name plus optional key — but is `package` rather than `fileprivate`
/// so the no-effect-warning helpers below can return it. Keys
/// partition the binding space (Dagger semantics): unkeyed deps only
/// match unkeyed consumers, keyed deps only match same-keyed
/// consumers, so classification proceeds per `(type, key)` slot
/// independently.
package struct LazyConsumerKey: Hashable, Sendable {
    package let canonicalType: String
    package let keyIdentifier: String?

    package init(type: String, keyIdentifier: String? = nil) {
        self.canonicalType = canonicalTypeName(type)
        self.keyIdentifier = keyIdentifier
    }
}

/// How a binding identity (`T`, or `T` under a particular key) is
/// referenced across every consumer in the partition.
///
/// - `directOnly`: every consumer references `T` directly. Codegen
///   constructs `T` eagerly at bootstrap.
/// - `lazyOnly`: every consumer references `Lazy<T>`. Codegen defers
///   `T`'s construction inside a `Lazy` factory closure.
/// - `mixed`: at least one direct consumer AND at least one
///   `Lazy<T>` consumer exist. `T` is constructed eagerly (the
///   direct consumer forces it), so the `Lazy<T>` wrapper is
///   ceremonial — Wire emits a no-effect warning at each `Lazy<T>`
///   site (see `lazyNoEffectWarnings`).
///
/// The local per-T rule (a direct consumer anywhere → T eager) is
/// deliberate. The transitive variant (T deferred iff all consumers
/// are themselves Lazy-deferred recursively) is documented but not
/// pursued — see Documentation/Notes/LazyTypeSupport.md "Why local,
/// not transitive" for the rationale.
package enum LazyConsumerClassification: Sendable, Equatable {
    case directOnly
    case lazyOnly
    case mixed
}

/// Classify every binding-identity slot referenced by the given
/// bindings' dependencies. Each slot in the result is the union over
/// every consumer in the input: if any consumer references `T`
/// directly, `T` is at-least-`directOnly`; if any references
/// `Lazy<T>`, at-least-`lazyOnly`; if both, `mixed`.
///
/// Slots with no consumers don't appear in the result (the
/// classification is only meaningful for types something depends on).
///
/// Input shape: a flat list of bindings whose deps share a single
/// resolution scope. Callers iterate the per-partition binding sets
/// from `aggregate.allBindings` and call this per-partition, since
/// `Lazy<T>` is intra-scope only and a `Lazy<T>` in scope A doesn't
/// see direct consumers in scope B.
package func classifyLazyConsumers(
    in bindings: [DiscoveredBinding]
) -> [LazyConsumerKey: LazyConsumerClassification] {
    var hasDirect: Set<LazyConsumerKey> = []
    var hasLazy: Set<LazyConsumerKey> = []
    for binding in bindings {
        for dep in binding.dependencies {
            let key = LazyConsumerKey(type: dep.type, keyIdentifier: dep.keyIdentifier)
            if dep.isLazyWrapped {
                hasLazy.insert(key)
            } else {
                hasDirect.insert(key)
            }
        }
    }
    var result: [LazyConsumerKey: LazyConsumerClassification] = [:]
    for key in hasDirect.union(hasLazy) {
        switch (hasDirect.contains(key), hasLazy.contains(key)) {
        case (true, true): result[key] = .mixed
        case (true, false): result[key] = .directOnly
        case (false, true): result[key] = .lazyOnly
        case (false, false): break
        }
    }
    return result
}

// MARK: - No-effect warning

/// Emit a `Warning` at every `Lazy<T>` consumer site whose `T` is in
/// the `.mixed` classification — `T` is constructed eagerly anyway
/// because another consumer references it directly, so the `Lazy`
/// wrapper is ceremonial.
///
/// Warning shape (matching the Swift compiler's
/// `file:line:col: warning:` convention):
///
///     X.swift:8:17: warning: 'Lazy<DatabasePool>' has no deferral effect here — 'DatabasePool' is constructed eagerly for another consumer
///     X.swift:15:23: note: 'DatabasePool' is also injected directly here
///     X.swift:8:17: note: inject 'DatabasePool' directly to avoid the wrapper, or remove the direct injection if deferral was intended
///
/// The note points at one direct-consumer site (the first one
/// encountered in input order) so the user can navigate to who's
/// forcing the eager construction. A second note carries the two
/// fix-it suggestions — remove the wrapper, or remove the direct
/// injection — since either resolution is valid and Wire can't pick
/// for the user.
///
/// Warnings are returned sorted by `(file, line, column)` so output
/// is stable across runs regardless of the input iteration order.
package func lazyNoEffectWarnings(
    in bindings: [DiscoveredBinding]
) -> [Warning] {
    let classification = classifyLazyConsumers(in: bindings)
    guard classification.contains(where: { $0.value == .mixed }) else { return [] }

    var firstDirectConsumerLocation: [LazyConsumerKey: SourceLocation] = [:]
    for binding in bindings {
        for dep in binding.dependencies where !dep.isLazyWrapped {
            let key = LazyConsumerKey(type: dep.type, keyIdentifier: dep.keyIdentifier)
            if firstDirectConsumerLocation[key] == nil {
                firstDirectConsumerLocation[key] = dep.location
            }
        }
    }

    var warnings: [Warning] = []
    for binding in bindings {
        for dep in binding.dependencies where dep.isLazyWrapped {
            let key = LazyConsumerKey(type: dep.type, keyIdentifier: dep.keyIdentifier)
            guard classification[key] == .mixed else { continue }
            guard let directLocation = firstDirectConsumerLocation[key] else { continue }
            let innerType = dep.type
            warnings.append(
                Warning(
                    location: dep.location,
                    message:
                        "'Lazy<\(innerType)>' has no deferral effect here — '\(innerType)' is constructed eagerly for another consumer",
                    notes: [
                        Warning.Note(
                            location: directLocation,
                            message: "'\(innerType)' is also injected directly here"
                        ),
                        Warning.Note(
                            location: dep.location,
                            message:
                                "inject '\(innerType)' directly to avoid the wrapper, or remove the direct injection if deferral was intended"
                        ),
                    ]
                )
            )
        }
    }
    return warnings.sorted { $0.location < $1.location }
}
