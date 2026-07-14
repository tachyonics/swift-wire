import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Shared `@Inject`-driven initialiser synthesis for the component macros that
/// construct a type from its dependencies — `@Singleton`/`@Scoped` (via
/// `SingletonMacro`) and `@Factory` (via `FactoryMacro`).
///
/// All of them determine the canonical initialiser the same way: a user-written
/// `@Inject init` wins; otherwise Wire generates one from `@Inject` stored
/// properties (or `init()` when there are none). This namespace walks the
/// primary declaration's members once, diagnoses invalid `@Inject` placements,
/// and renders the initialiser. Only the extras differ per macro (`@Singleton`
/// also emits a `static key`).
enum InjectableInitSynthesis {
    /// One user-provided initialiser, with a flag for whether it carries
    /// `@Inject`. The validation rules all reduce to combinations of this
    /// list's contents.
    struct UserInitInfo {
        let initDecl: InitializerDeclSyntax
        let hasInjectAttribute: Bool
    }

    /// One injection point on the host type — the parameter the synthesised
    /// init takes for a given `@Inject` property.
    struct InjectionPoint {
        let name: String
        let type: String
    }

    /// One non-`@Inject`, non-static stored property whose binding has no
    /// default value and isn't computed — i.e. the synthesised init won't
    /// know how to set it. Captured for later diagnosis.
    struct UninitialisedProperty {
        let binding: PatternBindingSyntax
        let name: String
    }

    /// Everything the macros need to know about the primary declaration, built
    /// by a single pass over the member list so the rest never has to re-walk.
    struct DeclarationAnalysis {
        var userInits: [UserInitInfo] = []
        var injectionPoints: [InjectionPoint] = []
        var hasUserKey: Bool = false
        var uninitialisedStoredProperties: [UninitialisedProperty] = []

        /// The user initialisers marked `@Inject` — the canonical init(s).
        /// Exactly one is valid; the diagnostics fire on 0 (with other inits
        /// present) or >1.
        var markedInits: [UserInitInfo] {
            userInits.filter(\.hasInjectAttribute)
        }
    }

    /// Walk the primary declaration's members exactly once and bucket them into
    /// the pieces the macros need: user-provided initialisers (with their
    /// `@Inject` flag), `@Inject` stored-property injection points, presence of
    /// a user-supplied `static key`, and stored properties the synthesised init
    /// won't initialise. Extensions are invisible to the macro — the build
    /// plugin's whole-file scan catches init-in-extension conflicts.
    static func analyse(_ declaration: some DeclGroupSyntax) -> DeclarationAnalysis {
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
                // Static properties don't take part in instance init. The only
                // thing we care about is whether one of them is the
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
                // `weak var` `@Inject` properties don't become init parameters —
                // Swift won't let init parameters be `weak`, and the build
                // plugin's post-construction assignment block does the wiring
                // (storage stays `weak var x: T?`, defaulting to nil at init).
                // A `weak let`, by contrast, CAN be initialised in the
                // synthesised init (the single write a `let` allows), so it
                // flows through as an ordinary init parameter — constructor-
                // injected, and so a cycle *participant*, not a cycle-breaker.
                // See Documentation/Notes/OptionalMatchingAndCycles.md and
                // WeakInjectionSupport.md.
                //
                // Mutual exclusivity with @Inject init: non-weak *and* weak-let
                // properties are injection points (they become init params), so
                // both conflict with an @Inject init via the `injectionPoints`
                // check below. Only `weak var` is the carve-out.
                let isWeak = varDecl.modifiers.contains { $0.name.text == "weak" }
                let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)
                if isWeak && !isLet { continue }
                // Each binding under an `@Inject var` becomes one injection
                // point — `@Inject var a, b: Dep` is two points.
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

            // Non-`@Inject`, non-static stored property: each binding has to be
            // initialised somehow. Computed (accessor block) and defaulted
            // (initializer clause) bindings are fine; anything else is captured
            // for later diagnosis.
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

    /// Emit Wire-specific diagnostics for invalid combinations of `@Inject`
    /// placements found in the analysis.
    ///
    /// The three @Inject-related checks are mutually exclusive on the
    /// configurations they fire for, so at most one set of init-related
    /// diagnostics emits per declaration:
    /// - Multiple inits marked `@Inject`.
    /// - User-provided init(s) with no `@Inject` marker on any of them.
    /// - `@Inject` on both an init and a stored property.
    ///
    /// Plus an unrelated check that runs only when Wire is generating the init:
    /// stored properties the synthesised init won't initialise. When the user
    /// provides their own init, Swift's "didn't initialise all properties"
    /// diagnostic fires at their init site if anything's missed, which is
    /// clearer than Wire reporting it here.
    static func diagnoseInitConfiguration(
        analysis: DeclarationAnalysis,
        context: some MacroExpansionContext
    ) {
        let markedInits = analysis.markedInits
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
            // User provided init(s) but none marked @Inject. Wire can't pick
            // one; require the user to mark exactly one.
            for userInit in analysis.userInits {
                context.diagnose(
                    Diagnostic(
                        node: Syntax(userInit.initDecl),
                        message: WireDiagnostic.unmarkedUserInit
                    )
                )
            }
        } else if markedInits.count == 1 && !analysis.injectionPoints.isEmpty {
            // @Inject on init AND stored property. The marked init's parameters
            // are the dependency declaration; @Inject on properties duplicates
            // that information ambiguously.
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

    /// Render the synthesised init from the collected injection points.
    static func renderInit(typeInfo: HostTypeInfo, injectionPoints: [InjectionPoint]) -> DeclSyntax {
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

/// Captures the bits of an annotated type declaration the component macros
/// need: its name (with generic parameters), access prefix, and whether it's
/// generic. Returns `nil` for a declaration that isn't a struct/class/actor.
struct HostTypeInfo {
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

// MARK: - SwiftSyntax conveniences

extension AttributeListSyntax {
    /// `true` if the list contains an attribute whose name matches `name`
    /// (e.g. "Inject" matches `@Inject`). Tolerates an SE-0491 module selector
    /// qualifying the macro with Wire's own module (`@Wire::Inject` ≡
    /// `@Inject`) so that a user who qualifies the host macro — and its members
    /// — consistently still expands correctly. Only Wire's selector is
    /// stripped; `@OtherModule::Inject` is a different module's macro. See
    /// `MultiModuleComposition.md`.
    func hasAttribute(named name: String) -> Bool {
        contains { element in
            guard let attr = element.as(AttributeSyntax.self) else { return false }
            let collapsed = attr.attributeName.trimmedDescription.filter { !$0.isWhitespace }
            return collapsed == name || collapsed == "Wire::\(name)"
        }
    }
}
