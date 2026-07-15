// Contributor-proxy synthesis — the plugin half of the route-contributor proxy (M5.3, 3.1c).
//
// An adapter annotation declaring `.contributesProxy(to: key, proxyTypePrefix: prefix)` (WireMVC's
// `@Controller`) does NOT contribute the annotated binding itself. Its macro generates a peer type
// `<prefix><Binding>` that holds the binding (constructed its ordinary way) plus any factories the
// binding's input-edge use-sites demand, conforms to the adapter's contributor protocol, and carries
// the witness. This pass synthesises that proxy's *binding*: a scope-bound type depending on the
// controller — and, after the factory pass runs, on the demanded factories — that contributes to the
// key in the controller's place. The controller stays a plain, footgun-free binding.
//
// The proxy is generic exactly when the controller is (the lifted-repository pattern): it restates the
// controller's generic parameters and depends on `Controller<Params>`, which threads the graph's lift
// parameter transitively (see `undeterminedGenericParameters` / `bridgedDependencyIdentity`).
//
// Domain-free: Wire wraps a binding in a synthesised contributor and never learns "controller".

/// Synthesise a contributor proxy beside each `.contributesProxy` binding and re-attribute that
/// binding's input-edge use-sites (factory / dependency) onto the proxy, so the later factory and
/// adapter-dependency passes land those edges on the proxy — which folds the middleware — rather than
/// the now-plain controller. Returns the updated bindings and use-sites; runs after alias contributions
/// and before adapter-dependency / factory synthesis.
package func applyContributorProxies(
    to allBindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> (bindings: [Partition: [DiscoveredBinding]], useSites: [ContributionAliasUseSite]) {
    let directiveByController = contributorProxyDirectives(annotations: annotations, useSites: useSites)
    guard !directiveByController.isEmpty else { return (allBindings, useSites) }

    // Synthesise a proxy beside each proxied controller, recording controller identity → proxy identity.
    var proxyIdentityByController: [String: String] = [:]
    var result = allBindings
    for (partition, bindings) in allBindings {
        var proxies: [DiscoveredBinding] = []
        for binding in bindings {
            guard case .scopeBound(let controller) = binding,
                let identity = binding.aliasTargetIdentity,
                let directive = directiveByController[identity]
            else { continue }
            let proxy = contributorProxyBinding(for: controller, key: directive.key, prefix: directive.prefix)
            proxyIdentityByController[identity] = proxy.qualifiedTypeName
            proxies.append(.scopeBound(proxy))
        }
        if !proxies.isEmpty { result[partition] = bindings + proxies }
    }

    let reattributed = reattributingInputEdges(
        useSites,
        toProxies: proxyIdentityByController,
        annotations: annotations
    )
    return (result, reattributed)
}

/// Map each proxied controller's identity to the proxy directive (multibinding key + type-name prefix)
/// it carries, reading the `.contributesProxy` annotations' use-sites. Empty when nothing requests a
/// proxy — the pass then no-ops.
private func contributorProxyDirectives(
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [String: (key: String, prefix: String)] {
    var proxyAnnotations: [String: (key: String, prefix: String)] = [:]
    for annotation in annotations {
        if case .contributesProxy(let key, let prefix) = annotation.capability {
            proxyAnnotations[annotation.annotationName] = (key, prefix)
        }
    }
    var directiveByController: [String: (key: String, prefix: String)] = [:]
    for site in useSites {
        if let directive = proxyAnnotations[site.annotationName] {
            directiveByController[site.targetIdentity] = directive  // first-seen wins
        }
    }
    return directiveByController
}

/// Re-point each input-edge (factory / dependency) use-site sitting on a proxied controller at that
/// controller's proxy, so the factory and adapter-dependency passes land the edge on the proxy — the
/// type that folds the middleware. Other use-sites (and the inert `@Controller` site itself) pass
/// through unchanged.
private func reattributingInputEdges(
    _ useSites: [ContributionAliasUseSite],
    toProxies proxyIdentityByController: [String: String],
    annotations: [DiscoveredAdapterAnnotation]
) -> [ContributionAliasUseSite] {
    let inputEdgeAnnotations = Set(
        annotations
            .filter { $0.capability == .injectsFactoryOnArgument || $0.capability == .injectsDependencyOnArgument }
            .map(\.annotationName)
    )
    return useSites.map { site in
        guard inputEdgeAnnotations.contains(site.annotationName),
            let proxyIdentity = proxyIdentityByController[site.targetIdentity]
        else { return site }
        return ContributionAliasUseSite(
            annotationName: site.annotationName,
            targetIdentity: proxyIdentity,
            argument: site.argument,
            location: site.location,
            originModule: site.originModule
        )
    }
}

/// The proxy binding for one `.contributesProxy` controller — a scope-bound `<prefix><Controller>`
/// generic exactly as the controller is, depending on the controller (spelled with the controller's
/// own generic parameters, `Controller<Params>`, so a generic controller threads transitively), and
/// contributing to the directive's key. The macro emits the type + its initialiser; the demanded
/// factory dependencies are appended later by the factory-synthesis pass.
func contributorProxyBinding(
    for controller: DiscoveredScopeBoundType,
    key: String,
    prefix: String
) -> DiscoveredScopeBoundType {
    let controllerDependencyType =
        controller.genericParameterNames.isEmpty
        ? controller.typeName
        : "\(controller.typeName)<\(controller.genericParameterNames.joined(separator: ", "))>"
    return DiscoveredScopeBoundType(
        typeName: prefix + controller.typeName,
        qualifiedTypeName: prefix + controller.qualifiedTypeName,
        typeKind: "struct",
        genericParameterNames: controller.genericParameterNames,
        genericParameterConstraints: controller.genericParameterConstraints,
        dependencies: [
            DependencyParameter(
                name: "controller",
                type: controllerDependencyType,
                kind: .injectInitParameter,
                location: controller.location
            )
        ],
        location: controller.location,
        accessLevel: controller.accessLevel,
        contributions: [Contribution(keyReference: key, location: controller.location)],
        originModule: controller.originModule
    )
}
