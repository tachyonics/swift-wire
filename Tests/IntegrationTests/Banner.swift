import Wire

/// Module-scope `@Provides func` whose parameters become real graph
/// dependencies. Exercises the function-form provider in the topo
/// sort — `makeBanner` is constructed only after both `AppName` and
/// `BuildNumber` are bound.
struct Banner: Sendable {
    let text: String
}

@Provides
func makeBanner(appName: AppName, buildNumber: BuildNumber) -> Banner {
    Banner(text: "\(appName.value) #\(buildNumber.value)")
}
