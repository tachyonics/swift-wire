import Wire

/// Axis A gate: a `@Scoped(seed:) enum` **scope block** — a group of
/// `@Provides` producers all scoped to a seed, the scope-axis sibling of
/// `@Container`. The seed is declared once on the block, not on each
/// producer.
///
/// Exercises every dependency direction a scoped producer can take:
///   - a `@Provides` *function* that reads the seed (in-scope) and borrows
///     the process-wide `Logger` singleton (parent graph),
///   - a `@Provides` *property* (a per-scope constant),
///   - a scope-bound consumer (`OrderProcessor`) that injects both.
///
/// What this proves: the block's producers land in the `(nil, OrderSeed)`
/// partition and flow through `orchestrateSeedScope` like any other scope
/// binding — Axis A needed no graph or codegen change, only discovery
/// routing off the enclosing block.

struct OrderSeed: Sendable {
    let orderID: String
}

struct OrderContext: Sendable {
    let label: String
}

struct AuditTag: Sendable {
    let value: String
}

@Scoped(seed: OrderSeed.self)
enum OrderProviders {
    /// Function form: reads the seed and borrows the `Logger` singleton.
    @Provides static func makeContext(seed: OrderSeed, logger: Logger) -> OrderContext {
        OrderContext(label: logger.log("order:\(seed.orderID)"))
    }

    /// Property form: a per-scope constant.
    @Provides static let auditTag: AuditTag = AuditTag(value: "audit")
}

@Scoped(seed: OrderSeed.self, allowUnused: true)
struct OrderProcessor {
    @Inject var context: OrderContext
    @Inject var auditTag: AuditTag
    @Inject var seed: OrderSeed

    func summary() -> String {
        "\(context.label) | \(auditTag.value) | \(seed.orderID)"
    }
}
