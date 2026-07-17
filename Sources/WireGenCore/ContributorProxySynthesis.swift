// Contributor-proxy synthesis — the plugin half of the contributor proxy (M5.3, 3.1c).
//
// An adapter annotation declaring `.contributesProxy(to: key, proxyTypePrefix: prefix)` (e.g. WireMVC's
// `@Controller`) does NOT contribute the annotated binding itself. Its macro generates a peer type
// `<prefix><Binding>` that holds the binding (constructed its ordinary way) plus any factories the
// binding's input-edge use-sites demand, conforms to the adapter's contributor protocol, and carries
// the adapter's witness. This pass synthesises that proxy's *binding*: a scope-bound type depending on
// the subject binding — and, after the factory pass runs, on the demanded factories — that contributes
// to the key in the subject's place. The subject stays a plain, footgun-free binding.
//
// The proxy is generic exactly when the subject is: it restates the subject's generic parameters and
// depends on `Subject<Params>`, which threads the graph's lift parameter transitively (see
// `undeterminedGenericParameters` / `bridgedDependencyIdentity`).
//
// Domain-free: Wire wraps a binding in a synthesised contributor; it never learns what the binding is.

/// Synthesise a contributor proxy beside each `.contributesProxy` binding and re-attribute that
/// binding's input-edge use-sites (factory / dependency) onto the proxy, so the later factory and
/// adapter-dependency passes land those edges on the proxy — the type they are lifted onto — rather
/// than the now-plain subject. Returns the updated bindings and use-sites; runs after alias
/// contributions and before adapter-dependency / factory synthesis.
package func applyContributorProxies(
    to allBindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> (
    bindings: [Partition: [DiscoveredBinding]],
    useSites: [ContributionAliasUseSite],
    proxyIdentities: Set<String>
) {
    let directiveBySubject = contributorProxyDirectives(annotations: annotations, useSites: useSites)
    guard !directiveBySubject.isEmpty else { return (allBindings, useSites, []) }

    // Synthesise a proxy beside each proxied subject, recording subject identity → proxy identity.
    var proxyBySubject: [String: String] = [:]
    var result = allBindings
    for (partition, bindings) in allBindings {
        var proxies: [DiscoveredBinding] = []
        for binding in bindings {
            guard case .scopeBound(let subject) = binding,
                let identity = binding.aliasTargetIdentity,
                let directive = directiveBySubject[identity]
            else { continue }
            let proxy = contributorProxyBinding(for: subject, key: directive.key, prefix: directive.prefix)
            proxyBySubject[identity] = proxy.qualifiedTypeName
            proxies.append(.scopeBound(proxy))
        }
        if !proxies.isEmpty { result[partition] = bindings + proxies }
    }

    let reattributed = reattributingInputEdges(useSites, toProxies: proxyBySubject, annotations: annotations)
    // The qualified names of the proxies synthesised here — the plugin renders each one's *structural*
    // declaration (`renderContributorProxyDeclaration`) into the consumer graph file, since Phase A moves
    // proxy-type emission out of the adapter macro and into the plugin.
    return (result, reattributed, Set(proxyBySubject.values))
}

/// Map each proxied subject's identity to the proxy directive (multibinding key + type-name prefix) it
/// carries, reading the `.contributesProxy` annotations' use-sites. Empty when nothing requests a proxy
/// — the pass then no-ops.
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
    var directiveBySubject: [String: (key: String, prefix: String)] = [:]
    for site in useSites {
        if let directive = proxyAnnotations[site.annotationName] {
            directiveBySubject[site.targetIdentity] = directive  // first-seen wins
        }
    }
    return directiveBySubject
}

/// Re-point each input-edge (factory / dependency) use-site sitting on a proxied subject at that
/// subject's proxy, so the factory and adapter-dependency passes land the edge on the proxy — the type
/// they are lifted onto. Other use-sites (and the inert proxy-annotation site itself) pass through
/// unchanged.
private func reattributingInputEdges(
    _ useSites: [ContributionAliasUseSite],
    toProxies proxyBySubject: [String: String],
    annotations: [DiscoveredAdapterAnnotation]
) -> [ContributionAliasUseSite] {
    let inputEdgeAnnotations = Set(
        annotations
            .filter { $0.capability == .injectsFromGraph }
            .map(\.annotationName)
    )
    return useSites.map { site in
        guard inputEdgeAnnotations.contains(site.annotationName),
            let proxyIdentity = proxyBySubject[site.targetIdentity]
        else { return site }
        return ContributionAliasUseSite(
            annotationName: site.annotationName,
            targetIdentity: proxyIdentity,
            argument: site.argument,
            arguments: site.arguments,
            location: site.location,
            originModule: site.originModule
        )
    }
}

/// The proxy binding for one `.contributesProxy` subject — a scope-bound `<prefix><Subject>` generic
/// exactly as the subject is, depending on the subject (spelled with the subject's own generic
/// parameters, `Subject<Params>`, so a generic subject threads transitively) and contributing to the
/// directive's key. The subject is the proxy's first, **unlabelled** dependency, so Wire names no
/// member of the adapter's proxy type; the macro emits the type + its initialiser, and the demanded
/// factory dependencies are appended later by the factory-synthesis pass.
func contributorProxyBinding(
    for subject: DiscoveredScopeBoundType,
    key: String,
    prefix: String
) -> DiscoveredScopeBoundType {
    let subjectDependencyType =
        subject.genericParameterNames.isEmpty
        ? subject.typeName
        : "\(subject.typeName)<\(subject.genericParameterNames.joined(separator: ", "))>"
    return DiscoveredScopeBoundType(
        typeName: prefix + subject.typeName,
        qualifiedTypeName: prefix + subject.qualifiedTypeName,
        typeKind: "struct",
        genericParameterNames: subject.genericParameterNames,
        genericParameterConstraints: subject.genericParameterConstraints,
        // Restated on the emitted proxy struct (generic exactly as the subject) so a
        // `where`-constrained subject's proxy still type-checks. See `renderContributorProxyDeclaration`.
        genericWhereClause: subject.genericWhereClause,
        dependencies: [
            DependencyParameter(
                name: nil,  // positional — the proxy's initialiser takes the subject unlabelled
                type: subjectDependencyType,
                kind: .injectInitParameter,
                location: subject.location
            )
        ],
        location: subject.location,
        accessLevel: subject.accessLevel,
        contributions: [Contribution(keyReference: key, location: subject.location)],
        originModule: subject.originModule
    )
}
