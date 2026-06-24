// Small standalone discovery-result models, split out of Discovery.swift
// to keep that file under the length cap. Each is a plain value type
// captured during the parse and consumed at validation time.

/// One module-scope `typealias` declaration captured during discovery.
/// Used at validation time to enrich missing-binding diagnostics: if
/// `@Inject var x: UserID` fails to resolve but `UserID` is a typealias
/// of a type that IS bound, a `note:` line points at the underlying
/// type so the user understands why the lookup didn't match. Typealiases
/// are not unwrapped during resolution — `typealias UserID = UUID`
/// followed by separate keyed bindings for each is a legitimate
/// discriminator pattern.
package struct DiscoveredTypealias: Sendable {
    /// The typealias's own name, as written (e.g. `"UserID"`).
    package let name: String
    /// The right-hand-side type expression, trimmed (e.g. `"UUID"`).
    package let underlyingType: String
    package let location: SourceLocation

    package init(name: String, underlyingType: String, location: SourceLocation) {
        self.name = name
        self.underlyingType = underlyingType
        self.location = location
    }
}

/// One `init` site found inside an extension that doesn't carry
/// `@Inject`. Recorded as a candidate; resolves to a warning when the
/// extended type is `@Singleton`-annotated somewhere in the module —
/// the macro-generated init either collides with this one (Swift
/// redeclaration error) or silently shadows it. The Wire diagnostic
/// fires before either of those confusing outcomes does.
package struct NonInjectExtensionInit: Sendable {
    /// Simple name of the extended type — what we cross-reference
    /// against the module-wide `@Singleton`-name set.
    package let extendedType: String
    /// Anchor at the `init` keyword.
    package let location: SourceLocation

    package init(extendedType: String, location: SourceLocation) {
        self.extendedType = extendedType
        self.location = location
    }
}
