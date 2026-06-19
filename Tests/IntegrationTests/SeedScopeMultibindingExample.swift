import Wire

/// End-to-end exercise of a multibinding inside a `@Scoped(seed:)` scope.
/// The contributors and consumer are scope-bound, so the aggregate is
/// built per scope from the scope's own contributors (one contributor
/// even reads the seed) — proving within-scope fan-in. A borrowed
/// singleton's contribution would stay with the default graph; cross-scope
/// contribution into a scope aggregate isn't supported.

struct ReportSeed: Sendable {
    let name: String
}

protocol ReportSection {
    func render() -> String
}

enum ReportRegistry {
    static let sections = CollectedKey<any ReportSection>()
}

@Scoped(seed: ReportSeed.self) @Contributes(to: ReportRegistry.sections, withOrder: 1)
struct HeaderSection: ReportSection {
    @Inject var reportSeed: ReportSeed

    func render() -> String { "header:\(reportSeed.name)" }
}

@Scoped(seed: ReportSeed.self) @Contributes(to: ReportRegistry.sections, withOrder: 2)
struct BodySection: ReportSection {
    func render() -> String { "body" }
}

@Scoped(seed: ReportSeed.self)
struct Report {
    @Inject(ReportRegistry.sections) var sections: [any ReportSection]

    func render() -> [String] { sections.map { $0.render() } }
}
