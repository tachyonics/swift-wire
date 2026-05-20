/// Cross-reference `UnannotatedExtensionProvides` candidates collected
/// during discovery against the module-wide `@Container`-name set.
/// Each candidate whose extended type matches a discovered
/// `@Container` produces a warning — the user probably meant
/// `@Container extension Foo` but wrote a plain `extension Foo`, and
/// the `@Provides` inside is silently falling through to the default
/// graph.
package func unannotatedExtensionContainerWarnings(
    candidates: [UnannotatedExtensionProvides],
    containerNames: Set<String>
) -> [Warning] {
    candidates.compactMap { candidate -> Warning? in
        guard containerNames.contains(candidate.extendedType) else { return nil }
        return Warning(
            location: candidate.location,
            message:
                "@Provides '\(candidate.providerName)' in an unannotated extension of '\(candidate.extendedType)' falls through to the default graph — mark the extension @Container to contribute to '\(candidate.extendedType)'s container instead."
        )
    }
}

/// Candidates whose extended type isn't declared anywhere in this
/// module (and isn't a `@Container` either — those are handled by
/// `unannotatedExtensionContainerWarnings`) almost certainly extend
/// an imported type. The binding still works (the generated code can
/// reach `ImportedType.x` through the propagated imports), but it's a
/// pattern worth surfacing: if `ImportedType` is a `@Container`
/// declared in another module, discovery can't see that and the
/// binding falls into the default graph silently.
///
/// Complex extension targets (`Foo.Bar`, `Array<Int>`, anything
/// containing `.` or `<`) are skipped — we can't reliably tell
/// whether the qualified or specialised form refers to a local type
/// without resolving Swift's name lookup, so we err toward silence
/// rather than false positives.
package func crossModuleExtensionWarnings(
    candidates: [UnannotatedExtensionProvides],
    containerNames: Set<String>,
    declaredTypeNames: Set<String>
) -> [Warning] {
    candidates.compactMap { candidate -> Warning? in
        let extendedType = candidate.extendedType
        if containerNames.contains(extendedType) { return nil }
        if declaredTypeNames.contains(extendedType) { return nil }
        if extendedType.contains(".") || extendedType.contains("<") { return nil }
        return Warning(
            location: candidate.location,
            message:
                "@Provides '\(candidate.providerName)' in an extension of '\(extendedType)' — '\(extendedType)' isn't declared in this module, so the binding falls through to the default graph and any @Container on '\(extendedType)' elsewhere isn't visible to discovery. Move the declaration to module scope or to a type declared in this module if the fall-through wasn't intentional."
        )
    }
}
