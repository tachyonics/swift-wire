import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireRoutingPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [HarnessRouteMacro.self]
}
