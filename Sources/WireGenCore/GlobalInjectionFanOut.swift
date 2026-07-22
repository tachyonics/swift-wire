// Global-injection fan-out — the pass half of `.injectsPeerFromGraphIntoAll` (M5.5 Phase 5).
//
// An adapter annotation declaring `.injectsPeerFromGraphIntoAll(peer:, collatingInto:)` (WireMVC's
// `@WireMVCBootstrap`) reinterprets its co-located peer annotation (its `@Middleware`): each peer
// use-site injects its argument onto **every proxy collating into the key**, instead of the peer's own
// self-scope `.injectsFromGraph` (which targets the annotated declaration's own proxy). This is the one
// fan-out input edge — a single directive spreads across a whole multibinding's proxies — so a global
// `@Middleware` on the composition root folds onto every route-contributor proxy.
//
// It is a use-site *rewrite*, the same shape as `reattributingInputEdges`: it deletes the root-targeting
// peer use-site and re-emits one per collating proxy. Everything downstream — `applyAdapterDependencies`
// appending `_wire<X>`, factory synthesis, proxy-struct emission — runs unchanged, and because the
// re-emitted use-sites keep the peer's annotation name, the argument-kind dispatch (factory / keyed /
// by-type) is inherited. Runs after `applyContributorProxies` (proxies + their contribution keys known)
// and before the input-edge passes.
//
// Domain-free: Wire spreads a peer's input edges across the proxies of a key; it never learns what the
// peer is.

/// Rewrite the use-site list so each `.injectsPeerFromGraphIntoAll` directive's peer use-sites fan out
/// onto every synthesised proxy collating into the directive's key. `proxyIdentities` (from
/// `applyContributorProxies`) bounds the fan-out to synthesised proxies, so the edge never lands on a
/// user-written contributor that couldn't absorb the synthetic field. No directive present, or no proxy
/// collating into the key, leaves the list untouched.
package func applyGlobalInjectionFanOut(
    to bindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite],
    proxyIdentities: Set<String>
) -> [ContributionAliasUseSite] {
    // The (peer, key) each reinterpreting annotation carries, by annotation name.
    var directiveByAnnotationName: [String: (peer: String, key: String)] = [:]
    for annotation in annotations {
        if case .injectsPeerFromGraphIntoAll(let peer, let key) = annotation.capability {
            directiveByAnnotationName[annotation.annotationName] = (peer, key)
        }
    }
    guard !directiveByAnnotationName.isEmpty else { return useSites }

    // A reinterpreting annotation is inert until a use-site pins it to a declaration; that declaration's
    // identity → the directive it reinterprets its peers by (first-seen wins, as `contributorProxyDirectives`).
    var reinterpretByDecl: [String: (peer: String, key: String)] = [:]
    for site in useSites {
        if let directive = directiveByAnnotationName[site.annotationName] {
            reinterpretByDecl[site.targetIdentity] = directive
        }
    }
    guard !reinterpretByDecl.isEmpty else { return useSites }

    // For each key a reinterpreter targets, the identities of the synthesised proxies collating into it —
    // the fan-out destinations. Sorted + deduped: the bindings dictionary iterates unordered, and a proxy
    // is registered in every partition that consumes it, so the same identity recurs.
    let keysInPlay = Set(reinterpretByDecl.values.map(\.key))
    var proxyIdentitiesByKey: [String: [String]] = [:]
    for partitionBindings in bindings.values {
        for binding in partitionBindings {
            guard let identity = binding.aliasTargetIdentity, proxyIdentities.contains(identity) else { continue }
            for contribution in binding.contributions where keysInPlay.contains(contribution.keyReference) {
                proxyIdentitiesByKey[contribution.keyReference, default: []].append(identity)
            }
        }
    }
    for key in proxyIdentitiesByKey.keys {
        proxyIdentitiesByKey[key] = Array(Set(proxyIdentitiesByKey[key]!)).sorted()
    }

    // Drop each reinterpreted peer use-site sitting on a reinterpreter and re-emit it once per proxy
    // collating into that reinterpreter's key (in the peer's source order — one whole expansion per peer
    // use-site — so a proxy's fanned-in edges keep declaration order). Everything else passes through.
    var rewritten: [ContributionAliasUseSite] = []
    for site in useSites {
        guard let directive = reinterpretByDecl[site.targetIdentity], site.annotationName == directive.peer
        else {
            rewritten.append(site)
            continue
        }
        for proxyIdentity in proxyIdentitiesByKey[directive.key] ?? [] {
            rewritten.append(
                ContributionAliasUseSite(
                    annotationName: site.annotationName,
                    targetIdentity: proxyIdentity,
                    argument: site.argument,
                    arguments: site.arguments,
                    location: site.location,
                    originModule: site.originModule
                )
            )
        }
    }
    return rewritten
}
