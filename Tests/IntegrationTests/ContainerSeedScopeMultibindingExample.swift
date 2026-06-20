import Wire

/// End-to-end exercise of a multibinding in the `(container, seed)`
/// partition cell — a `@Scoped(seed:)` scope *inside* a `@Container`. The
/// key is declared in the container; the contributors and consumer are
/// scope-bound within the container's seed scope. This completes the
/// partition matrix and verifies that the cross-container check (which
/// compares only the container axis) *allows* a contribution whose scope
/// differs from the key's but whose container matches.

struct WidgetSeed: Sendable {
    let theme: String
}

protocol Widget {
    func render() -> String
}

@Container
enum WidgetContainer {
    static let widgets = CollectedKey<any Widget>()

    @Scoped(seed: WidgetSeed.self) @Contributes(to: WidgetContainer.widgets, withOrder: 1)
    struct ButtonWidget: Widget {
        @Inject var widgetSeed: WidgetSeed

        func render() -> String { "button:\(widgetSeed.theme)" }
    }

    @Scoped(seed: WidgetSeed.self) @Contributes(to: WidgetContainer.widgets, withOrder: 2)
    struct LabelWidget: Widget {
        func render() -> String { "label" }
    }

    @Scoped(seed: WidgetSeed.self)
    struct WidgetView {
        @Inject(WidgetContainer.widgets) var widgets: [any Widget]

        func render() -> [String] { widgets.map { $0.render() } }
    }
}
