import Wire

/// No-dependency leaf in the integration graph. Exercises the
/// "macro synthesises a parameterless init" path.
@Singleton
struct Logger {
    func log(_ message: String) -> String {
        "[log] \(message)"
    }
}
