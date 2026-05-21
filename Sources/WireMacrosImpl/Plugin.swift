import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SingletonMacro.self,
        ScopedMacro.self,
        InjectMacro.self,
        ProvidesMacro.self,
        ContainerMacro.self,
    ]
}
