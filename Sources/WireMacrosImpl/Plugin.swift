import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SingletonMacro.self,
        InjectMacro.self,
    ]
}
