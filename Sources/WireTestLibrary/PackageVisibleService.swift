import Wire

/// A `package`-access `@Singleton` published by a same-package Wire-aware
/// sibling. The `IntegrationTests` consumer composes it across the module
/// boundary; `package` is reachable across modules of the *same package*,
/// so it clears the cross-module visibility threshold without `public`
/// (7f's same-package branch — `WireTestLibrary` is a `.target` dependency,
/// not external). An `internal` binding here, by contrast, would fail the
/// threshold, and a `package` binding consumed across a *package* boundary
/// (the external harness) would need `public`.
@Singleton(allowUnused: true)
package struct PackageVisibleService {
    package let label: String

    @Inject
    package init() {
        self.label = "package-visible"
    }
}
