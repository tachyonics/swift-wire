import Wire

/// Iteration 5β validation-gate fixture for the collected flavour: the
/// `CollectedKey<any Service>` case from `M1_PLAN.md`, with **three**
/// contributors covering **both** the ordered and the unordered path.
///
/// The same three services fan into two keys via repeated `@Contributes`:
///   - `ServiceGate.ranked` — every contribution carries `withOrder:`, so
///     the aggregate is in rank order (1, 2, 3) regardless of source order.
///   - `ServiceGate.sourceOrdered` — no `withOrder:` anywhere, so the
///     aggregate falls back to source-declaration order.
///
/// What this proves over the two-contributor `MultibindingExample`: a
/// 3-way `withOrder:` sort actually sorts (not just swaps a pair), the
/// unranked path preserves source order, and one contributor set yields
/// two different orderings depending on the key it's aggregated under.

protocol Service {
    func name() -> String
}

enum ServiceGate {
    static let ranked = CollectedKey<any Service>()
    static let sourceOrdered = CollectedKey<any Service>()
}

// Source order: Alpha, Bravo, Charlie. Ranked order: Bravo, Charlie, Alpha.
@Singleton
@Contributes(to: ServiceGate.ranked, withOrder: 3)
@Contributes(to: ServiceGate.sourceOrdered)
struct AlphaService: Service {
    func name() -> String { "alpha" }
}

@Singleton
@Contributes(to: ServiceGate.ranked, withOrder: 1)
@Contributes(to: ServiceGate.sourceOrdered)
struct BravoService: Service {
    func name() -> String { "bravo" }
}

@Singleton
@Contributes(to: ServiceGate.ranked, withOrder: 2)
@Contributes(to: ServiceGate.sourceOrdered)
struct CharlieService: Service {
    func name() -> String { "charlie" }
}

@Singleton(allowUnused: true)
struct ServiceGateHost {
    @Inject(ServiceGate.ranked) var ranked: [any Service]
    @Inject(ServiceGate.sourceOrdered) var sourceOrdered: [any Service]
}
