import SwiftDiagnostics
import XCTest

@testable import WireMacrosImpl

/// Direct unit tests for `WireDiagnostic`. The macro-expansion tests in
/// `SingletonMacroTests` exercise `message` and `severity` (the test
/// framework's `DiagnosticSpec` matches on those by default) but not
/// `diagnosticID`. These tests pin the IDs as a stable contract:
/// downstream tooling can suppress or filter individual Wire diagnostic
/// kinds by `MessageID`, so changes to the `id` strings are user-visible.
final class WireDiagnosticTests: XCTestCase {
    func test_uninitialisedStoredProperty_diagnosticID() {
        let diagnostic = WireDiagnostic.uninitialisedStoredProperty(name: "x")
        XCTAssertEqual(
            diagnostic.diagnosticID,
            MessageID(domain: "Wire", id: "uninitialised-stored-property")
        )
    }

    func test_multipleInjectInits_diagnosticID() {
        XCTAssertEqual(
            WireDiagnostic.multipleInjectInits.diagnosticID,
            MessageID(domain: "Wire", id: "multiple-inject-inits")
        )
    }

    func test_unmarkedUserInit_diagnosticID() {
        XCTAssertEqual(
            WireDiagnostic.unmarkedUserInit.diagnosticID,
            MessageID(domain: "Wire", id: "unmarked-user-init")
        )
    }

    func test_injectOnInitAndProperty_diagnosticID() {
        XCTAssertEqual(
            WireDiagnostic.injectOnInitAndProperty.diagnosticID,
            MessageID(domain: "Wire", id: "inject-on-init-and-property")
        )
    }

    func test_allDiagnosticsHaveErrorSeverity() {
        // Every Wire diagnostic is an error today. If a future warning-
        // severity case is added, this test prompts a deliberate update
        // rather than letting severity drift silently.
        let cases: [WireDiagnostic] = [
            .uninitialisedStoredProperty(name: "x"),
            .multipleInjectInits,
            .unmarkedUserInit,
            .injectOnInitAndProperty,
        ]
        for diagnostic in cases {
            XCTAssertEqual(diagnostic.severity, .error, "\(diagnostic) was not .error")
        }
    }
}
