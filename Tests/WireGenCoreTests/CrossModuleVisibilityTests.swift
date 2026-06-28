import Testing

@testable import WireGenCore

/// Iteration 7f: the cross-module visibility threshold. A binding composed
/// from another module is referenced by the consumer's generated graph, so
/// its access must clear a higher bar than the in-module `internal` floor —
/// `package` for a same-package sibling, `public` for an external-package
/// library. `private`/`fileprivate` stay 5α's; these cover the
/// cross-module-specific cases with origin-aware messaging.
@Suite("CrossModuleVisibility")
struct CrossModuleVisibilityTests {
    private func singleton(
        _ name: String,
        module: String,
        access: AccessLevel
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                accessLevel: access,
                originModule: module
            )
        )
    }

    private func diagnose(
        _ binding: DiscoveredBinding,
        consumer: String,
        external: Set<String> = []
    ) -> [Diagnostic] {
        crossModuleVisibilityDiagnostics(
            bindings: [binding],
            consumerModule: consumer,
            externalModules: external
        )
    }

    @Test func ownModuleInternalIsFine() {
        // In-module keeps the 5α `internal` floor — no cross-module error.
        #expect(diagnose(singleton("A", module: "App", access: .internal), consumer: "App").isEmpty)
    }

    @Test func samePackageForeignInternalNeedsPackage() {
        let diagnostics = diagnose(
            singleton("A", module: "SiblingLib", access: .internal),
            consumer: "App"
        )
        #expect(diagnostics.contains { $0.message.contains("at least 'package'") })
        #expect(diagnostics.contains { $0.message.contains("sibling module 'SiblingLib'") })
    }

    @Test func samePackageForeignPackageIsFine() {
        #expect(
            diagnose(singleton("A", module: "SiblingLib", access: .package), consumer: "App").isEmpty
        )
    }

    @Test func samePackageForeignPublicIsFine() {
        #expect(
            diagnose(singleton("A", module: "SiblingLib", access: .public), consumer: "App").isEmpty
        )
    }

    @Test func externalForeignInternalNeedsPublic() {
        let diagnostics = diagnose(
            singleton("A", module: "ExtLib", access: .internal),
            consumer: "App",
            external: ["ExtLib"]
        )
        #expect(diagnostics.contains { $0.message.contains("Make it 'public'") })
        #expect(diagnostics.contains { $0.message.contains("external-package module 'ExtLib'") })
    }

    @Test func externalForeignPackageNeedsPublic() {
        // `package` is fine same-package but not across packages.
        let diagnostics = diagnose(
            singleton("A", module: "ExtLib", access: .package),
            consumer: "App",
            external: ["ExtLib"]
        )
        #expect(diagnostics.contains { $0.message.contains("across packages") })
    }

    @Test func externalForeignPublicIsFine() {
        #expect(
            diagnose(
                singleton("A", module: "ExtLib", access: .public),
                consumer: "App",
                external: ["ExtLib"]
            ).isEmpty
        )
    }
}
