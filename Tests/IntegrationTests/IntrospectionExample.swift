import Wire

// Fixture for IntrospectionTests: a leaf and a root that consumes it, giving the
// wiring model a known singleton, a known dependency edge, and a root (allowUnused,
// since nothing else in the graph consumes it).
@Singleton
struct IntrospectionLeaf {
    @Inject init() {}
}

@Singleton(allowUnused: true)
struct IntrospectionRoot {
    let leaf: IntrospectionLeaf

    @Inject init(leaf: IntrospectionLeaf) {
        self.leaf = leaf
    }
}
