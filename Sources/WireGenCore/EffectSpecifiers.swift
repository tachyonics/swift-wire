import SwiftSyntax

/// Extract `(isAsync, isThrowing)` flags from a function-shaped
/// effect-specifier syntax node. Used for `@Provides func` return
/// effects and `@Inject init` effects. Absent specifiers (the
/// common sync case) return `(false, false)`.
func functionEffectFlags(
    _ specifiers: FunctionEffectSpecifiersSyntax?
) -> (isAsync: Bool, isThrowing: Bool) {
    guard let specifiers else { return (false, false) }
    return (
        isAsync: specifiers.asyncSpecifier != nil,
        isThrowing: specifiers.throwsClause != nil
    )
}

/// Same as `functionEffectFlags` but for accessor-shaped effect
/// specifiers (the `get async throws` shape on a computed
/// `@Provides var`). Different SwiftSyntax type, identical
/// extraction logic.
func accessorEffectFlags(
    _ specifiers: AccessorEffectSpecifiersSyntax?
) -> (isAsync: Bool, isThrowing: Bool) {
    guard let specifiers else { return (false, false) }
    return (
        isAsync: specifiers.asyncSpecifier != nil,
        isThrowing: specifiers.throwsClause != nil
    )
}

/// Extract effect flags from a `@Provides var x: T { get async throws { ... } }`
/// computed property binding. Walks the accessor block to find the
/// `get` accessor (or the shorthand `{ ... }` form whose
/// `accessorBlock` carries effect specifiers directly), then reads
/// its effect specifiers. Stored bindings (no accessor block) have
/// no effects.
func computedPropertyEffectFlags(
    _ binding: PatternBindingSyntax
) -> (isAsync: Bool, isThrowing: Bool) {
    guard let accessorBlock = binding.accessorBlock else { return (false, false) }
    switch accessorBlock.accessors {
    case .getter:
        // Implicit-getter form `var x: T { expression }` — no effect
        // specifiers possible on the shorthand. Treated as sync.
        return (false, false)
    case .accessors(let accessorDecls):
        // Walk the accessor list and pick the `get` accessor. Other
        // accessors (`set`, `_modify`) don't matter for the
        // construction call colour — we only invoke the getter.
        for accessor in accessorDecls {
            let kind = accessor.accessorSpecifier.tokenKind
            guard case .keyword(.get) = kind else { continue }
            return accessorEffectFlags(accessor.effectSpecifiers)
        }
        return (false, false)
    }
}
