@testable import WireGenCore

/// A stable mock location derived from a file path. Line and column
/// default to 1 so synthetic test bindings have something deterministic
/// for `formattedPrefix`-style assertions.
func mockLocation(_ file: String, line: Int = 1, column: Int = 1) -> SourceLocation {
    SourceLocation(file: file, line: line, column: column)
}
