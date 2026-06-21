import Wire

/// An intentionally-empty multibinding: a `CollectedKey` with no
/// contributors, consumed as `[any Hook]`. The key is declared
/// `allowUnused: true` to silence the empty-multibinding warning, and the
/// consumer bootstraps to an empty array — exercising the empty-aggregate
/// codegen (`[] as [any Hook]`) and the key silencer end-to-end.

protocol Hook {
    func fire()
}

enum HookRegistry {
    static let all = CollectedKey<any Hook>(allowUnused: true)
}

@Singleton(allowUnused: true)
struct HookHost {
    @Inject(HookRegistry.all) var hooks: [any Hook]
}
