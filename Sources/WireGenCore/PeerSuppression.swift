// Peer suppression — the pass half of `.suppressesPeers` (M5.5 front layer).
//
// An adapter annotation declaring `.suppressesPeers([...])` (WireMVC's `@WireMVCBootstrap`) tells WireGen
// to skip its default handling of the listed peer annotations sitting on the same declaration — the
// adapter's own codegen owns them. Concretely: a *global* `@Middleware` on the composition root must not be
// injected as a dependency of the root binding by the `.injectsFromGraph` pass; the front-layer route
// generator reads it and folds it from the graph instead. This pass drops those peer use-sites before the
// input-edge passes (dependency / factory synthesis) run, so they never see them.
//
// Domain-free: a marker reserves certain co-located peers for its own downstream handling.

/// Drop each use-site whose annotation a co-located `.suppressesPeers` directive names — leaving every
/// other use-site (including the suppressor's own, which the input-edge passes ignore) untouched. No
/// suppressor present returns the list unchanged.
package func applyPeerSuppression(
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [ContributionAliasUseSite] {
    // The peer list each suppressing annotation carries, by annotation name.
    var peersByAnnotationName: [String: [String]] = [:]
    for annotation in annotations {
        if case .suppressesPeers(let peers) = annotation.capability {
            peersByAnnotationName[annotation.annotationName] = peers
        }
    }
    guard !peersByAnnotationName.isEmpty else { return useSites }

    // A suppressor is inert until a use-site pins it to a declaration; that declaration's identity → the
    // set of peer names suppressed on it (unioned if it carries more than one suppressor).
    var suppressedPeersByDecl: [String: Set<String>] = [:]
    for site in useSites {
        if let peers = peersByAnnotationName[site.annotationName] {
            suppressedPeersByDecl[site.targetIdentity, default: []].formUnion(peers)
        }
    }
    guard !suppressedPeersByDecl.isEmpty else { return useSites }

    return useSites.filter { site in
        guard let suppressed = suppressedPeersByDecl[site.targetIdentity] else { return true }
        return !suppressed.contains(site.annotationName)
    }
}
