/// Slot identity used to group `Lazy<T>` consumer evidence by
/// `(canonicalType, key)` — the same shape the graph builder uses
/// for `BindingIdentity`. Keys partition the binding space (Dagger
/// semantics): unkeyed deps only match unkeyed consumers, keyed deps
/// only match same-keyed consumers, so per-slot classification stays
/// independent across keys for the same type.
private struct LazyConsumerKey: Hashable {
    let canonicalType: String
    let keyIdentifier: String?

    init(type: String, keyIdentifier: String?) {
        self.canonicalType = canonicalTypeName(type)
        self.keyIdentifier = keyIdentifier
    }
}

/// Per-slot evidence accumulated by `lazyNoEffectWarnings` in a
/// single pass over the bindings. The warning fires for a slot when
/// both `firstDirectLocation` is set AND `lazySites` is non-empty
/// — i.e. T has both a direct consumer (forcing eager construction)
/// and at least one `Lazy<T>` consumer (whose wrapper is therefore
/// ceremonial).
private struct LazyConsumerEvidence {
    var firstDirectLocation: SourceLocation?
    /// Each Lazy-wrapped consumer's site, captured with the inner
    /// type text as the consumer wrote it. The original formatting
    /// is preserved in warning messages even though the slot key
    /// canonicalises whitespace away.
    var lazySites: [(innerType: String, location: SourceLocation)] = []
}

/// Emit a `Warning` at every `Lazy<T>` consumer site whose `T` also
/// has a direct (non-`Lazy`) consumer — `T` is constructed eagerly
/// anyway, so the `Lazy` wrapper is ceremonial.
///
/// The local per-T rule (a direct consumer anywhere → T eager) is
/// deliberate. The transitive variant (T deferred iff all consumers
/// are themselves Lazy-deferred recursively) is documented but not
/// pursued — see Documentation/Notes/LazyTypeSupport.md "Why local,
/// not transitive" for the rationale.
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
/// Implementation: single pass over the bindings accumulates per-slot
/// evidence (the first direct-consumer location and every Lazy
/// consumer's location + inner-type text). Warnings emit only for
/// slots that gathered both kinds of evidence — the
/// classify-then-walk-twice variant would do the same work three
/// times. The output is sorted by `(file, line, column)` so it's
/// deterministic regardless of input iteration order.
package func lazyNoEffectWarnings(
    in bindings: [DiscoveredBinding]
) -> [Warning] {
    var evidence: [LazyConsumerKey: LazyConsumerEvidence] = [:]
    for binding in bindings {
        for dep in binding.dependencies {
            let key = LazyConsumerKey(type: dep.type, keyIdentifier: dep.keyIdentifier)
            if dep.isLazyWrapped {
                evidence[key, default: LazyConsumerEvidence()].lazySites.append(
                    (innerType: dep.type, location: dep.location)
                )
            } else if evidence[key]?.firstDirectLocation == nil {
                evidence[key, default: LazyConsumerEvidence()].firstDirectLocation = dep.location
            }
        }
    }

    var warnings: [Warning] = []
    for slot in evidence.values {
        guard let directLocation = slot.firstDirectLocation, !slot.lazySites.isEmpty else {
            continue
        }
        for site in slot.lazySites {
            warnings.append(noEffectWarning(at: site, directLocation: directLocation))
        }
    }
    return warnings.sorted { $0.location < $1.location }
}

/// Render one no-effect warning, anchored at the `Lazy<T>` site,
/// with the direct-consumer note + fix-it note pair.
private func noEffectWarning(
    at site: (innerType: String, location: SourceLocation),
    directLocation: SourceLocation
) -> Warning {
    let innerType = site.innerType
    return Warning(
        location: site.location,
        message:
            "'Lazy<\(innerType)>' has no deferral effect here — '\(innerType)' is constructed eagerly for another consumer",
        notes: [
            Warning.Note(
                location: directLocation,
                message: "'\(innerType)' is also injected directly here"
            ),
            Warning.Note(
                location: site.location,
                message:
                    "inject '\(innerType)' directly to avoid the wrapper, or remove the direct injection if deferral was intended"
            ),
        ]
    )
}
