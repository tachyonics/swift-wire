import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Singleton` — type-level macro.
///
/// Generates two things:
/// 1. An initialiser Wire calls to construct the type at bootstrap time.
/// 2. A `static let key: BindingKey<Self>` for graph identity.
///
/// ## Initialiser source
///
/// Wire determines the canonical initialiser by these rules, applied in
/// order:
/// - **No user-provided initialisers** → Wire generates one from
///   `@Inject`-marked stored properties (or `init()` if there are none).
/// - **Any user-provided initialisers** → exactly one of them must be
///   marked `@Inject`. Wire calls that one. Other initialisers exist as
///   ordinary Swift inits but Wire ignores them.
///
/// `@Inject` is exclusive: it belongs on stored properties *or* on one
/// initialiser, not both. Mixing produces a compile error.
///
/// Validation errors emitted by this macro:
/// - Multiple initialisers marked `@Inject`.
/// - User-provided initialiser with no `@Inject` marker (any parameter
///   list, including `init()`).
/// - `@Inject` on both an initialiser and a stored property.
///
/// ## Static key
///
/// Generated unless the user provides their own `static let key` (or
/// `static var key`) — typically to give the binding a named identifier
/// for disambiguation.
///
/// ## Extensions
///
/// The macro only sees the primary type declaration, not extensions:
/// - **When Wire generates the init** (no user init in primary), do not
///   add inits in extensions. If the extension init's signature matches
///   the generated one, Swift's redeclaration check fires. If it
///   differs, the extension init exists alongside Wire's generated init,
///   but Wire calls its own — there's no way to tell the macro to defer
///   to an extension init, because the macro can't see it. To make Wire
///   call a custom init, put it in the primary declaration and mark it
///   with `@Inject`.
/// - **When the user provides an `@Inject`-marked init in the primary
///   declaration**, extensions can add any additional non-canonical inits
///   (e.g. `init(from decoder:)` for `Codable`); Wire only knows about
///   the marked init in primary.
///
/// The macro itself can't validate this — extensions are invisible to
/// it — but the Wire build plugin's whole-file scan catches both
/// failure modes and emits Wire-specific diagnostics pointing at the
/// offending extension init. The remedy is the same in either case:
/// keep the canonical initialiser in the primary declaration.
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

        let userInits = collectUserInits(in: declaration)
        let markedInits = userInits.filter { $0.hasInjectAttribute }
        let injectionPoints = collectInjectionPoints(in: declaration)
        let hasUserKey = hasUserProvidedKey(in: declaration)

        diagnoseInitialiserConfiguration(
            userInits: userInits,
            markedInits: markedInits,
            injectionPoints: injectionPoints,
            in: declaration,
            context: context
        )

        var members: [DeclSyntax] = []

        if userInits.isEmpty {
            members.append(renderInit(typeInfo: typeInfo, injectionPoints: injectionPoints))
        }
        // else: skip init generation. The marked init (or the user's
        // unmarked init that's about to be flagged by validation above) is
        // the source of truth.

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

    /// One user-provided initialiser, with a flag for whether it carries
    /// `@Inject`. The validation rules above all reduce to combinations of
    /// this list's contents.
    private struct UserInitInfo {
        let initDecl: InitializerDeclSyntax
        let hasInjectAttribute: Bool
    }

    /// Collect every `init` the user has written on the primary
    /// declaration (extensions are invisible to the macro — see the type's
    /// doc comment).
    private static func collectUserInits(in declaration: some DeclGroupSyntax) -> [UserInitInfo] {
        declaration.memberBlock.members.compactMap { member -> UserInitInfo? in
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { return nil }
            let hasInject = initDecl.attributes.hasAttribute(named: "Inject")
            return UserInitInfo(initDecl: initDecl, hasInjectAttribute: hasInject)
        }
    }

    /// Walk the user's initialiser/property configuration and emit any
    /// Wire-specific diagnostics for invalid combinations.
    ///
    /// The three @Inject-related checks are mutually exclusive on the
    /// configurations they fire for, so at most one set of init-related
    /// diagnostics emits per declaration:
    /// - Multiple inits marked `@Inject`.
    /// - User-provided init(s) with no `@Inject` marker on any of them.
    /// - `@Inject` on both an init and a stored property.
    ///
    /// Plus an unrelated check that runs only when Wire is generating the
    /// init: stored properties that the synthesised init won't initialise.
    /// When the user provides their own init, Swift's "didn't initialise
    /// all properties" diagnostic fires at their init site if anything's
    /// missed, which is clearer than Wire reporting it here.
    private static func diagnoseInitialiserConfiguration(
        userInits: [UserInitInfo],
        markedInits: [UserInitInfo],
        injectionPoints: [InjectionPoint],
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext
    ) {
        if markedInits.count > 1 {
            for markedInit in markedInits {
                context.diagnose(
                    Diagnostic(
                        node: Syntax(markedInit.initDecl),
                        message: WireDiagnostic.multipleInjectInits
                    )
                )
            }
        } else if markedInits.isEmpty && !userInits.isEmpty {
            // User provided init(s) but none marked @Inject. Wire can't
            // pick one; require the user to mark exactly one.
            for userInit in userInits {
                context.diagnose(
                    Diagnostic(
                        node: Syntax(userInit.initDecl),
                        message: WireDiagnostic.unmarkedUserInit
                    )
                )
            }
        } else if markedInits.count == 1 && !injectionPoints.isEmpty {
            // @Inject on init AND stored property. The marked init's
            // parameters are the dependency declaration; @Inject on
            // properties duplicates that information ambiguously.
            context.diagnose(
                Diagnostic(
                    node: Syntax(markedInits[0].initDecl),
                    message: WireDiagnostic.injectOnInitAndProperty
                )
            )
        }

        if userInits.isEmpty {
            diagnoseUninitialisedStoredProperties(in: declaration, context: context)
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
                points.append(
                    InjectionPoint(
                        name: pattern.identifier.text,
                        type: typeAnnotation.type.trimmedDescription
                    )
                )
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

                let propName =
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    ?? binding.pattern.trimmedDescription

                context.diagnose(
                    Diagnostic(
                        node: Syntax(binding),
                        message: WireDiagnostic.uninitialisedStoredProperty(name: propName)
                    )
                )
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

        let params =
            injectionPoints
            .map { "\($0.name): \($0.type)" }
            .joined(separator: ", ")
        let assignments =
            injectionPoints
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
    let accessPrefix: String  // e.g. "public " or "" — trailing space included when present

    init?(declaration: some DeclGroupSyntax) {
        let baseName: String
        let genericClause: GenericParameterClauseSyntax?
        let modifiers: DeclModifierListSyntax

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            baseName = structDecl.name.text
            genericClause = structDecl.genericParameterClause
            modifiers = structDecl.modifiers
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            baseName = classDecl.name.text
            genericClause = classDecl.genericParameterClause
            modifiers = classDecl.modifiers
        } else if let actorDecl = declaration.as(ActorDeclSyntax.self) {
            baseName = actorDecl.name.text
            genericClause = actorDecl.genericParameterClause
            modifiers = actorDecl.modifiers
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
    case multipleInjectInits
    case unmarkedUserInit
    case injectOnInitAndProperty

    var message: String {
        switch self {
        case .uninitialisedStoredProperty(let name):
            return "Stored property '\(name)' must have a default value, be a computed property, or be marked @Inject."
        case .multipleInjectInits:
            return "Only one initialiser can be marked @Inject. Remove @Inject from the others."
        case .unmarkedUserInit:
            return
                "User-provided initialiser must be marked @Inject so Wire knows which one to call. Either add @Inject to this initialiser, or remove the initialiser entirely and let Wire generate one from @Inject stored properties."
        case .injectOnInitAndProperty:
            return
                "@Inject is on both an initialiser and a stored property. Pick one source of truth — either the @Inject-marked initialiser declares dependencies via its parameters, or @Inject-marked properties declare them via Wire's auto-generated init."
        }
    }

    var diagnosticID: MessageID {
        let identifier: String
        switch self {
        case .uninitialisedStoredProperty: identifier = "uninitialised-stored-property"
        case .multipleInjectInits: identifier = "multiple-inject-inits"
        case .unmarkedUserInit: identifier = "unmarked-user-init"
        case .injectOnInitAndProperty: identifier = "inject-on-init-and-property"
        }
        return MessageID(domain: "Wire", id: identifier)
    }

    var severity: DiagnosticSeverity {
        .error
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
