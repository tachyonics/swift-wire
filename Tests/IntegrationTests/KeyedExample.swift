import Wire

/// End-to-end fixture for sitting 1c's compile-time type assertions
/// plus sitting 1b's keyed resolution. Declares a named key on the
/// `AppName` type, adds a second `@Provides AppName` keyed by that
/// name (coexisting with the unkeyed module-scope `appName`), and a
/// `@Singleton` consumer that pulls the keyed binding via `@Inject`.
///
/// Bootstrap is expected to wire `KeyedConsumer.alternate` to the
/// keyed provider — verifying the `(type, key)` graph identity end-to-
/// end and that the generated `_WireKeyChecks.swift` accepts the
/// matching `BindingKey<AppName>` / `AppName` pairing.
extension AppName {
    static let alternate = BindingKey<AppName>()
}

@Provides(AppName.alternate)
let alternateAppName: AppName = AppName(value: "alternate")

@Singleton
struct KeyedConsumer {
    @Inject(AppName.alternate) var alternate: AppName

    func describe() -> String {
        "consumer with \(alternate.value)"
    }
}
