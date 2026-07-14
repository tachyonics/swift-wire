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
/// order (shared with the other component macros via
/// `InjectableInitSynthesis`):
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

        let analysis = InjectableInitSynthesis.analyse(declaration)
        InjectableInitSynthesis.diagnoseInitConfiguration(analysis: analysis, context: context)

        var members: [DeclSyntax] = []

        if analysis.userInits.isEmpty {
            members.append(
                InjectableInitSynthesis.renderInit(
                    typeInfo: typeInfo,
                    injectionPoints: analysis.injectionPoints
                )
            )
        }
        // else: skip init generation. The marked init (or the user's unmarked
        // init that's about to be flagged by validation) is the source of truth.

        if !analysis.hasUserKey {
            // The key's type identity is `Self` via `nameWithGenerics`, so it
            // automatically refers to the correct generic instantiation.
            //
            // Generic types can't have `static let` properties that refer to
            // their generic parameters — Swift disallows `static stored
            // properties not supported in generic types`. For those we emit a
            // `static var key { BindingKey<...>() }` computed property instead.
            // BindingKey carries no state (it's a phantom-typed marker), so
            // allocating a fresh instance per access is free.
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

/// Wire-specific diagnostic messages emitted by the component macros. Each
/// carries a stable `MessageID` so consumers can suppress or filter individual
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
