// Dead-factory warning: a `@Factory(key)` template declared but consumed by
// nothing in the build — no use-site references its key. The factory analogue of
// the dead-binding warning, and visibility-gated like it but tighter: only
// `internal` templates warn.
//
// A `package`/`public` template stays silent: a consumer may live in another module or package Wire
// can't see from here, so its being unconsumed in *this* build doesn't make it dead. An `internal`
// template can only be consumed in its own module, so no in-module consumer means it is genuinely dead.
// `fileprivate`/`private` never reach here (declaration-too-private already failed the build).
//
// Consumption is judged name-agnostically — a use-site is consuming if its argument is the template's
// key — over-approximating consumption is the safe direction for a warning: better to miss a dead
// factory than to warn a live one.
//
// Only templates whose `originModule` is the module being built are checked. A dependency's template is
// re-parsed during composition and the consumer emits the factory type when it consumes it, but a
// dependency's *unconsumed* templates are not this consumer's concern to flag.

/// Warn for each `internal` `@Factory` template owned by `owningModule` whose key no use-site
/// references. Output sorted by source location for stable build output.
package func deadFactoryDiagnostics(
    templates: [DiscoveredFactoryTemplate],
    useSites: [ContributionAliasUseSite],
    owningModule: String
) -> [Diagnostic] {
    var consumedKeys: Set<String> = []
    for site in useSites {
        if let key = factoryKeyArgument(site.argument) { consumedKeys.insert(key) }
    }

    return
        templates
        .filter { template in
            template.originModule == owningModule
                && template.accessLevel == .internal
                && !consumedKeys.contains(template.keyReference)
        }
        .map { template in
            Diagnostic(
                location: template.location,
                message:
                    "@Factory '\(template.typeName)' (key \(template.keyReference)) is declared but nothing in the build consumes it. Reference it from a consumer, raise it to 'package'/'public' if it's consumed outside this target, or remove it.",
                severity: .warning
            )
        }
        .sorted { $0.location < $1.location }
}
