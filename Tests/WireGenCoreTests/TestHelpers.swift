@testable import WireGenCore

/// A stable mock location derived from a file path. Line and column
/// default to 1 so synthetic test bindings have something deterministic
/// for `formattedPrefix`-style assertions.
func mockLocation(_ file: String, line: Int = 1, column: Int = 1) -> SourceLocation {
    SourceLocation(file: file, line: line, column: column)
}

/// The stand-in module name tests pass to `discover(...)` and to direct
/// binding/key constructions — the synthetic-context equivalent of the
/// consumer target name the build plugin supplies. `originModule` is a
/// required non-optional `String`, so tests model the real build by
/// always providing one.
let testModule = "TestModule"
