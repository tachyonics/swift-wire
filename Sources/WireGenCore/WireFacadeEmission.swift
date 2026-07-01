// The `_Wire` bootstrap façade — one non-generic enum aggregating every graph's
// entry point, so the call site (`_Wire.bootstrap()`) stays uniform whether or
// not the underlying graph type carries lifted generic parameters.

/// One entry point aggregated onto the `_Wire` façade: the method signature
/// (name, parameters, return type) and the call into the private bootstrap free
/// function. Collected as each graph struct is emitted, then rendered as a
/// single non-generic `_Wire` enum so the call site never changes shape when a
/// graph type becomes generic (opaque lifting).
struct BootstrapEntry {
    let signature: String
    let body: String
}

/// Emit the `_Wire` façade — every graph's bootstrap entry point as a static
/// method on one non-generic enum, so `_Wire.bootstrap()` (and the container/
/// scope variants) is the uniform call site regardless of whether the
/// underlying graph type carries lifted generic parameters.
func appendWireFacade(_ entries: [BootstrapEntry], into lines: inout [String]) {
    lines.append("")
    lines.append("internal enum _Wire {")
    for entry in entries {
        lines.append("    static func \(entry.signature) {")
        lines.append("        \(entry.body)")
        lines.append("    }")
    }
    lines.append("}")
}
