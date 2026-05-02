import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Singleton` — type-level macro generating:
/// - A `static let key: BindingKey<Self>` for graph identity, *unless* the
///   user has provided one explicitly. A user-provided key lets the type
///   carry a named identifier (e.g. for disambiguating same-type bindings).
/// - An `init(...)` taking one parameter per `@Inject` property on the
///   type, in declaration order, *unless* the user has provided any `init`.
///   A user-provided init suppresses both generation and the
///   uninitialised-stored-property diagnostic — the user's init takes
///   responsibility for initialisation and Swift validates it directly.
///
/// In both cases the principle is the same: the macro is a convenience.
/// If the user wants to customise, they write the member themselves and
/// the macro defers.
public struct SingletonMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Identify the host type and capture its access level.
        guard let typeInfo = HostTypeInfo(declaration: declaration) else {
            throw SingletonMacroError.unsupportedDeclaration
        }

        let hasUserInit = hasUserProvidedInit(in: declaration)
        let hasUserKey = hasUserProvidedKey(in: declaration)

        // Walk stored properties looking for those marked with @Inject.
        let injectionPoints = collectInjectionPoints(in: declaration)

        // Diagnose stored properties the synthesised init won't initialise.
        // Skip when the user has their own init — they own initialisation
        // and Swift's "didn't initialise" error fires directly at their init
        // if anything's missed, which is clearer than Wire reporting it
        // here.
        if !hasUserInit {
            diagnoseUninitialisedStoredProperties(in: declaration, context: context)
        }

        var members: [DeclSyntax] = []

        if !hasUserInit {
            members.append(renderInit(typeInfo: typeInfo, injectionPoints: injectionPoints))
        }

        if !hasUserKey {
            // The key's type identity is `Self` via `nameWithGenerics`, so
            // it automatically refers to the correct generic instantiation.
            let keyDecl: DeclSyntax = """
                \(raw: typeInfo.accessPrefix)static let key = BindingKey<\(raw: typeInfo.nameWithGenerics)>()
                """
            members.append(keyDecl)
        }

        return members
    }

    /// `true` if the host type declares any `init`. The macro defers to the
    /// user's init regardless of its parameter list — if the user's init
    /// doesn't take the right `@Inject` parameters, the build plugin's
    /// generated bootstrap will fail to compile when it tries to call it,
    /// surfacing the mismatch with a clear Swift diagnostic at the call
    /// site. Validating the user's init signature here is possible but more
    /// complex than it's worth at M1.
    private static func hasUserProvidedInit(in declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            member.decl.is(InitializerDeclSyntax.self)
        }
    }

    /// `true` if the host type declares a `static let key` (or `static var`)
    /// — typically for naming the binding with a specific identifier.
    private static func hasUserProvidedKey(in declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return false }
            let isStatic = varDecl.modifiers.contains { ["static", "class"].contains($0.name.text) }
            guard isStatic else { return false }
            return varDecl.bindings.contains { binding in
                binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "key"
            }
        }
    }

    // MARK: - Helpers

    /// One injection point on the host type — the parameter the synthesised
    /// init takes for a given `@Inject` property.
    private struct InjectionPoint {
        let name: String
        let type: String
    }

    /// Find every `@Inject`-attributed stored property on the type and
    /// produce one `InjectionPoint` per binding declared.
    private static func collectInjectionPoints(in declaration: some DeclGroupSyntax) -> [InjectionPoint] {
        var points: [InjectionPoint] = []

        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard varDecl.attributes.hasAttribute(named: "Inject") else { continue }

            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                guard let typeAnnotation = binding.typeAnnotation else { continue }
                points.append(InjectionPoint(
                    name: pattern.identifier.text,
                    type: typeAnnotation.type.trimmedDescription
                ))
            }
        }

        return points
    }

    /// Walk stored properties looking for ones the synthesised init won't
    /// know how to initialise: no `@Inject`, no default value, not a
    /// computed property, not `static`. Emit a Wire-specific diagnostic at
    /// each so the user gets a clear remedy at the offending property
    /// rather than Swift's "stored property requires explicit initializer"
    /// pointing at the synthesised init.
    private static func diagnoseUninitialisedStoredProperties(
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext
    ) {
        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            // `static`/`class` properties live on the type, not the instance —
            // they don't need to be initialised by the synthesised init.
            if varDecl.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) {
                continue
            }

            // `@Inject` properties become init parameters; they're handled
            // separately. (A property with both a default and `@Inject` is
            // still treated as `@Inject`; the default is shadowed by the
            // injected value. That's pointless but not invalid.)
            if varDecl.attributes.hasAttribute(named: "Inject") {
                continue
            }

            for binding in varDecl.bindings {
                // Computed property — fine, no init storage needed.
                if binding.accessorBlock != nil {
                    continue
                }
                // Has a default value — fine, init doesn't need to set it.
                if binding.initializer != nil {
                    continue
                }

                let propName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    ?? binding.pattern.trimmedDescription

                context.diagnose(Diagnostic(
                    node: Syntax(binding),
                    message: WireDiagnostic.uninitialisedStoredProperty(name: propName)
                ))
            }
        }
    }

    /// Render the synthesised init from the collected injection points.
    private static func renderInit(typeInfo: HostTypeInfo, injectionPoints: [InjectionPoint]) -> DeclSyntax {
        if injectionPoints.isEmpty {
            return """
                \(raw: typeInfo.accessPrefix)init() {
                }
                """
        }

        let params = injectionPoints
            .map { "\($0.name): \($0.type)" }
            .joined(separator: ", ")
        let assignments = injectionPoints
            .map { "    self.\($0.name) = \($0.name)" }
            .joined(separator: "\n")

        return """
            \(raw: typeInfo.accessPrefix)init(\(raw: params)) {
            \(raw: assignments)
            }
            """
    }
}

// MARK: - Host type inspection

/// Captures the bits of the annotated declaration the macro needs.
private struct HostTypeInfo {
    let nameWithGenerics: String
    let accessPrefix: String   // e.g. "public " or "" — trailing space included when present

    init?(declaration: some DeclGroupSyntax) {
        let baseName: String
        let genericClause: GenericParameterClauseSyntax?
        let modifiers: DeclModifierListSyntax

        if let s = declaration.as(StructDeclSyntax.self) {
            baseName = s.name.text
            genericClause = s.genericParameterClause
            modifiers = s.modifiers
        } else if let c = declaration.as(ClassDeclSyntax.self) {
            baseName = c.name.text
            genericClause = c.genericParameterClause
            modifiers = c.modifiers
        } else if let a = declaration.as(ActorDeclSyntax.self) {
            baseName = a.name.text
            genericClause = a.genericParameterClause
            modifiers = a.modifiers
        } else {
            return nil
        }

        if let clause = genericClause {
            let params = clause.parameters
                .map { $0.name.text }
                .joined(separator: ", ")
            self.nameWithGenerics = "\(baseName)<\(params)>"
        } else {
            self.nameWithGenerics = baseName
        }

        self.accessPrefix = HostTypeInfo.accessPrefix(from: modifiers)
    }

    private static func accessPrefix(from modifiers: DeclModifierListSyntax) -> String {
        let known: Set<String> = ["open", "public", "package", "internal", "fileprivate", "private"]
        for modifier in modifiers {
            let name = modifier.name.text
            if known.contains(name) {
                // The synthesised init's access matches the type's. We don't
                // emit "internal" explicitly since Swift defaults to it.
                return name == "internal" ? "" : "\(name) "
            }
        }
        return ""
    }
}

// MARK: - Errors

enum SingletonMacroError: Error, CustomStringConvertible {
    case unsupportedDeclaration

    var description: String {
        switch self {
        case .unsupportedDeclaration:
            return "@Singleton can only be applied to a struct, class, or actor."
        }
    }
}

// MARK: - Diagnostics

/// Wire-specific diagnostic messages emitted by the macros. Each carries a
/// stable `MessageID` so consumers can suppress or filter individual
/// diagnostic kinds without affecting others.
enum WireDiagnostic: DiagnosticMessage {
    case uninitialisedStoredProperty(name: String)

    var message: String {
        switch self {
        case .uninitialisedStoredProperty(let name):
            return "Stored property '\(name)' must have a default value, be a computed property, or be marked @Inject."
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .uninitialisedStoredProperty:
            return MessageID(domain: "Wire", id: "uninitialised-stored-property")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .uninitialisedStoredProperty:
            return .error
        }
    }
}

// MARK: - SwiftSyntax conveniences

extension AttributeListSyntax {
    /// `true` if the list contains an attribute whose name matches `name`
    /// (e.g. "Inject" matches `@Inject`). Macro names are matched leniently
    /// against the trimmed identifier; module-qualified names like
    /// `@Wire.Inject` aren't expected at the host source level.
    fileprivate func hasAttribute(named name: String) -> Bool {
        contains { element in
            guard let attr = element.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == name
        }
    }
}
