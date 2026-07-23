import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SingletonMacro.self,
        ScopedMacro.self,
        FactoryMacro.self,
        InjectMacro.self,
        ProvidesMacro.self,
        ContainerMacro.self,
        ContributesMacro.self,
        TeardownMacro.self,
        ReplacesMacro.self,
    ]
}
