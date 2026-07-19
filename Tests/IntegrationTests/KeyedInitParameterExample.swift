import Wire

/// End-to-end fixture for keyed injection through an `@Inject init` *parameter* rather than a stored
/// property. `@Inject(Key)` keys a property, but `@Inject` is a peer macro and can't attach to a parameter,
/// so a keyed initialiser parameter carries the `@Bind(Key)` property wrapper. Declares a named key on
/// `AppName`, a keyed `@Provides` for it (a distinct `AppName` from the unkeyed module-scope binding), and
/// a `@Singleton` whose init pulls the keyed binding by `@Bind`. Bootstrap must resolve it to the keyed
/// provider — verifying `@Bind` participates in the `(type, key)` graph identity exactly like `@Inject(Key)`,
/// and that the generated `_WireKeyChecks.swift` accepts the matching `BindingKey<AppName>` / `AppName` pair.
extension AppName {
    static let boundViaInit = BindingKey<AppName>()
}

@Provides(AppName.boundViaInit)
let boundViaInitAppName: AppName = AppName(value: "bound-via-init")

@Singleton(allowUnused: true)
struct KeyedInitConsumer {
    let name: AppName

    @Inject init(@Bind(AppName.boundViaInit) name: AppName) {
        self.name = name
    }

    func describe() -> String {
        "init consumer with \(name.value)"
    }
}
