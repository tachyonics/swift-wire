// Wire-aware opt-in marker (iteration 7c).
//
// The presence of this file is what tells a consuming target's build
// plugin that `WireTestLibrary` participates in Wire's cross-module
// composition — the plugin re-parses this target's sources and composes
// its public bindings into the consumer's graph. In M1 the marker is
// presence-only (no content contract); the M7 manifest optimization is
// what gives it content. See `Documentation/Notes/MultiModuleComposition.md`.
