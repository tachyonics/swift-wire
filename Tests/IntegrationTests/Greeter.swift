import Wire

/// Init-injection consumer. Exercises the "user-supplied `@Inject`
/// init takes precedence over property scanning" path. The macro
/// preserves this init verbatim and uses its parameter list as the
/// dependency declaration.
@Singleton
struct Greeter {
    let repository: UserRepository

    @Inject
    init(repository: UserRepository) {
        self.repository = repository
    }

    func greet(_ name: String) -> String {
        "\(name): \(repository.describe())"
    }
}
