import Wire

/// End-to-end exercise of `@Inject weak var` on an `actor` host.
/// Direct property assignment from outside actor isolation isn't
/// legal Swift, so Wire's codegen synthesises a setter extension
/// method on the actor and routes the post-init wire through it,
/// crossing isolation via `await`. The user's spelling stays
/// compact (`@Inject weak var`) and the framework handles the
/// indirection.
///
/// Two actor singletons that mutually reference each other:
///   - `Workshop` injects `Toolbelt` strongly via its init.
///   - `Toolbelt` injects `Workshop` weakly via `@Inject weak var`.
///
/// The weak side gives Wire its cycle-break (Toolbelt constructs
/// without Workshop at init time). After both exist, Wire calls
/// the generated `_wireSetWorkshop(_:)` extension method on the
/// Toolbelt actor with `await`. Once that runs, `toolbelt.workshop`
/// is set and the mutual reference is observable.
@Singleton
package actor Workshop {
    package let toolbelt: Toolbelt

    @Inject
    package init(toolbelt: Toolbelt) {
        self.toolbelt = toolbelt
    }
}

@Singleton
package actor Toolbelt {
    @Inject package weak var workshop: Workshop?
}
