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

        let analysis = analyseDeclaration(declaration)
        let markedInits = analysis.userInits.filter { $0.hasInjectAttribute }

        diagnoseInitialiserConfiguration(
            analysis: analysis,
            markedInits: markedInits,
            context: context
        )

        var members: [DeclSyntax] = []

        if analysis.userInits.isEmpty {
            members.append(renderInit(typeInfo: typeInfo, injectionPoints: analysis.injectionPoints))
        }
        // else: skip init generation. The marked init (or the user's
        // unmarked init that's about to be flagged by validation) is the
        // source of truth.

        if !analysis.hasUserKey {
            // The key's type identity is `Self` via `nameWithGenerics`, so
            // it automatically refers to the correct generic instantiation.
            //
            // Generic types can't have `static let` properties that refer
            // to their generic parameters — Swift disallows
            // `static stored properties not supported in generic types`.
            // For those we emit a `static var key { BindingKey<...>() }`
            // computed property instead. BindingKey carries no state
            // (it's a phantom-typed marker), so allocating a fresh
            // instance per access is free.
            let keyDecl: DeclSyntax
            if typeInfo.isGeneric {
                keyDecl = """
                    \(raw: typeInfo.accessPrefix)static var key: BindingKey<\(raw: typeInfo.nameWithGenerics)> {
                        BindingKey<\(raw: typeInfo.nameWithGenerics)>()
                    }
                    """
            } else {
                keyDecl = """
                    \(raw: typeInfo.accessPrefix)static let key = BindingKey<\(raw: typeInfo.nameWithGenerics)>()
                    """
            }
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

    /// One injection point on the host type — the parameter the synthesised
    /// init takes for a given `@Inject` property.
    private struct InjectionPoint {
        let name: String
        let type: String
    }

    /// One non-`@Inject`, non-static stored property whose binding has no
    /// default value and isn't computed — i.e. the synthesised init won't
    /// know how to set it. Captured by the analysis pass for later
    /// diagnosis.
    private struct UninitialisedProperty {
        let binding: PatternBindingSyntax
        let name: String
    }

    /// Everything `expansion` and `diagnoseInitialiserConfiguration` need
    /// to know about the primary declaration. Built by a single pass over
    /// the member list so the rest of the macro never has to re-walk.
    private struct DeclarationAnalysis {
        var userInits: [UserInitInfo] = []
        var injectionPoints: [InjectionPoint] = []
        var hasUserKey: Bool = false
        var uninitialisedStoredProperties: [UninitialisedProperty] = []
    }

    /// Walk the primary declaration's members exactly once and bucket
    /// them into the pieces the macro needs: user-provided initialisers
    /// (with their `@Inject` flag), `@Inject` stored-property injection
    /// points, presence of a user-supplied `static key`, and stored
    /// properties the synthesised init won't initialise.
    ///
    /// Subsequent validation and generation operate on the returned
    /// analysis without re-walking. Extensions are invisible to the macro
    /// — see the type's doc comment.
    private static func analyseDeclaration(
        _ declaration: some DeclGroupSyntax
    ) -> DeclarationAnalysis {
        var analysis = DeclarationAnalysis()

        for member in declaration.memberBlock.members {
            if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
                let hasInject = initDecl.attributes.hasAttribute(named: "Inject")
                analysis.userInits.append(
                    UserInitInfo(initDecl: initDecl, hasInjectAttribute: hasInject)
                )
                continue
            }

            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let isStatic = varDecl.modifiers.contains {
                ["static", "class"].contains($0.name.text)
            }
            let hasInject = varDecl.attributes.hasAttribute(named: "Inject")

            if isStatic {
                // Static properties don't take part in instance init. The
                // only thing we care about is whether one of them is the
                // user-supplied `key`.
                for binding in varDecl.bindings {
                    if binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "key" {
                        analysis.hasUserKey = true
                        break
                    }
                }
                continue
            }

            if hasInject {
                // `weak var` `@Inject` properties don't become init
                // parameters — Swift won't let init parameters be `weak`,
                // and the build plugin's post-construction assignment block
                // does the wiring (storage stays `weak var x: T?`,
                // defaulting to nil at init). A `weak let`, by contrast,
                // CAN be initialised in the synthesised init (the single
                // write a `let` allows), so it flows through as an ordinary
                // init parameter — constructor-injected, and so a cycle
                // *participant*, not a cycle-breaker. See
                // Documentation/Notes/OptionalMatchingAndCycles.md and
                // WeakInjectionSupport.md.
                //
                // Mutual exclusivity with @Inject init: non-weak *and*
                // weak-let properties are injection points (they become
                // init params), so both conflict with an @Inject init via
                // the `injectionPoints` check below. Only `weak var` is the
                // carve-out.
                let isWeak = varDecl.modifiers.contains { $0.name.text == "weak" }
                let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)
                if isWeak && !isLet { continue }
                // Each binding under an `@Inject var` becomes one
                // injection point — `@Inject var a, b: Dep` is two points.
                for binding in varDecl.bindings {
                    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                        continue
                    }
                    guard let typeAnnotation = binding.typeAnnotation else { continue }
                    analysis.injectionPoints.append(
                        InjectionPoint(
                            name: pattern.identifier.text,
                            type: typeAnnotation.type.trimmedDescription
                        )
                    )
                }
                continue
            }

            // Non-`@Inject`, non-static stored property: each binding has
            // to be initialised somehow. Computed (accessor block) and
            // defaulted (initializer clause) bindings are fine; anything
            // else is captured for later diagnosis.
            for binding in varDecl.bindings {
                if binding.accessorBlock != nil { continue }
                if binding.initializer != nil { continue }

                let propName =
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    ?? binding.pattern.trimmedDescription

                analysis.uninitialisedStoredProperties.append(
                    UninitialisedProperty(binding: binding, name: propName)
                )
            }
        }

        return analysis
    }

    /// Emit Wire-specific diagnostics for invalid combinations of
    /// `@Inject` placements found in the analysis.
    ///
    /// The three @Inject-related checks are mutually exclusive on the
    /// configurations they fire for, so at most one set of init-related
    /// diagnostics emits per declaration:
    /// - Multiple inits marked `@Inject`.
    /// - User-provided init(s) with no `@Inject` marker on any of them.
    /// - `@Inject` on both an init and a stored property.
    ///
    /// Plus an unrelated check that runs only when Wire is generating the
    /// init: stored properties the synthesised init won't initialise. When
    /// the user provides their own init, Swift's "didn't initialise all
    /// properties" diagnostic fires at their init site if anything's
    /// missed, which is clearer than Wire reporting it here.
    private static func diagnoseInitialiserConfiguration(
        analysis: DeclarationAnalysis,
        markedInits: [UserInitInfo],
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
        } else if markedInits.isEmpty && !analysis.userInits.isEmpty {
            // User provided init(s) but none marked @Inject. Wire can't
            // pick one; require the user to mark exactly one.
            for userInit in analysis.userInits {
                context.diagnose(
                    Diagnostic(
                        node: Syntax(userInit.initDecl),
                        message: WireDiagnostic.unmarkedUserInit
                    )
                )
            }
        } else if markedInits.count == 1 && !analysis.injectionPoints.isEmpty {
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

        if analysis.userInits.isEmpty {
            for property in analysis.uninitialisedStoredProperties {
                context.diagnose(
                    Diagnostic(
                        node: Syntax(property.binding),
                        message: WireDiagnostic.uninitialisedStoredProperty(name: property.name)
                    )
                )
            }
        }
    }

    // MARK: - Helpers

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
    let isGeneric: Bool

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
            self.isGeneric = true
        } else {
            self.nameWithGenerics = baseName
            self.isGeneric = false
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
