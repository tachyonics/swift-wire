import Wire

/// Exercises effect-aware emission for `@Provides var x: T { get async throws }`
/// — the computed-property accessor case. Discovery walks the
/// accessor block, finds the `get` accessor, reads its effect
/// specifiers, and tags the binding `isAsync: true, isThrowing: true`.
/// Codegen emits `let asyncMessage = try await AsyncFactories.asyncMessage`
/// at the call site (the property reference itself is the call).
package struct AsyncMessage: Sendable {
    package let payload: String
}

package enum AsyncFactories {
    @Provides
    package static var asyncMessage: AsyncMessage {
        get async throws {
            // Yield to the cooperative scheduler so the `await` is
            // semantically meaningful, not just syntactic.
            try await Task.sleep(nanoseconds: 1)
            return AsyncMessage(payload: "computed-property-resolved")
        }
    }
}
