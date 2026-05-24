/// Seed value for the test request scope. Carries an identifier so
/// scope-bound types can read it back and tests can assert distinct
/// scope entries received distinct seeds.
struct TestRequestSeed: Sendable {
    let id: String
}
