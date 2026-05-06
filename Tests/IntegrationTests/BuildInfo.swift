import Wire

/// Caseless enum used as a namespace for grouped configuration values.
/// `@Provides static let` here behaves identically to module-scope
/// `@Provides let` — `BuildInfo` is not `@Container`-annotated, so it's
/// just a Swift idiom for organisation, with no DI semantics attached
/// to the enclosing type.
struct BuildNumber: Sendable {
    let value: Int
}

enum BuildInfo {
    @Provides static let buildNumber: BuildNumber = BuildNumber(value: 42)
}
