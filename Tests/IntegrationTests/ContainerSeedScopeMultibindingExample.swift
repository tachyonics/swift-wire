import Wire

/// End-to-end exercise of multibindings across the `(container, nil)` and
/// `(container, seed)` partition cells *of the same container, same key*.
/// A container singleton and a container seed-scope type both contribute
/// to `WidgetContainer.widgets` with the **same** `withOrder: 2` — which
/// must not conflict, because each partition forms its own aggregate. Each
/// partition's consumer must see only its own partition's contributor.
///
/// This pins both partition-isolated *synthesis* (each aggregate picks its
/// own contributors) and partition-aware *diagnostics* (the duplicate-
/// `withOrder:` check is per partition, not module-wide).

struct WidgetSeed: Sendable {
    let theme: String
}

protocol Widget {
    func render() -> String
}

@Container
enum WidgetContainer {
    static let widgets = CollectedKey<any Widget>()

    // (WidgetContainer, nil) — container singleton partition.
    @Singleton @Contributes(to: WidgetContainer.widgets, withOrder: 2)
    struct SingletonWidget: Widget {
        func render() -> String { "singleton" }
    }

    @Singleton
    struct SingletonView {
        @Inject(WidgetContainer.widgets) var widgets: [any Widget]

        func render() -> [String] { widgets.map { $0.render() } }
    }

    // (WidgetContainer, WidgetSeed) — same key, same withOrder: 2.
    @Scoped(seed: WidgetSeed.self) @Contributes(to: WidgetContainer.widgets, withOrder: 2)
    struct ScopedWidget: Widget {
        @Inject var widgetSeed: WidgetSeed

        func render() -> String { "scoped:\(widgetSeed.theme)" }
    }

    @Scoped(seed: WidgetSeed.self)
    struct ScopedView {
        @Inject(WidgetContainer.widgets) var widgets: [any Widget]

        func render() -> [String] { widgets.map { $0.render() } }
    }
}
