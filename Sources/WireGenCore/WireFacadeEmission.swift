// The `Wire` bootstrap façade — every graph's entry point as a static method on
// one non-generic `internal enum Wire`, so the call site (`Wire.bootstrap()`)
// reads as a deliberate entry point and stays uniform whether or not the
// underlying graph type carries lifted generic parameters. `enum Wire` is
// internal (called only within the module that owns the graph) and coexists with
// `import Wire` without clashing — the module name and a local type of the same
// name resolve independently, so no `Wire<Module>` marker/extension is needed.

/// One entry point aggregated onto the façade: the method signature (name,
/// parameters, return type) and the call into the private bootstrap free
/// function. Collected as each graph struct is emitted, then rendered onto one
/// `enum Wire` so the call site never changes shape when a graph type becomes
/// generic (opaque lifting).
struct BootstrapEntry {
    let signature: String
    let body: String
}

/// Emit the `Wire` façade — every graph's bootstrap entry point as a static
/// method on one non-generic enum, so `Wire.bootstrap()` (and the container/scope
/// variants) is the uniform call site regardless of whether the underlying graph
/// type carries lifted generic parameters.
func appendWireFacade(_ entries: [BootstrapEntry], into lines: inout [String]) {
    lines.append("")
    lines.append("internal enum Wire {")
    for entry in entries {
        lines.append("    static func \(entry.signature) {")
        lines.append("        \(entry.body)")
        lines.append("    }")
    }
    lines.append("}")
}
