import SwiftSyntax

/// Attribute-name matching for Wire's macros, parsed from source by the
/// build plugin. Includes SE-0491 module-selector tolerance so a user may
/// qualify Wire's macros with its module (`@Wire::Singleton`) — see
/// `wireMacroNameMatches` and `MultiModuleComposition.md`.

/// Find the first attribute in the list matching `name`, or `nil`.
/// Used to reach the attribute's argument list when extracting a
/// key identifier from `@Inject(...)` / `@Provides(...)`.
func attribute(
    in attributes: AttributeListSyntax,
    named name: String
) -> AttributeSyntax? {
    for element in attributes {
        guard let attribute = element.as(AttributeSyntax.self) else { continue }
        if wireMacroNameMatches(attribute.attributeName.trimmedDescription, name) {
            return attribute
        }
    }
    return nil
}

func hasAttribute(
    _ attributes: AttributeListSyntax,
    named name: String
) -> Bool {
    attribute(in: attributes, named: name) != nil
}

/// Whether a Wire macro attribute carries `allowUnused: true` — the
/// dead-binding-warning silencer. Only a literal `true` counts; absent or
/// `false` returns `false`.
func allowUnusedFlag(from attribute: AttributeSyntax) -> Bool {
    guard case let .argumentList(arguments) = attribute.arguments,
        let argument = arguments.first(where: { $0.label?.text == "allowUnused" })
    else { return false }
    return argument.expression.as(BooleanLiteralExprSyntax.self)?.literal.text == "true"
}

/// Match an attribute's written name against a Wire macro name, tolerating
/// an SE-0491 module selector that qualifies it with Wire's own module:
/// `@Wire::Singleton` ≡ `@Singleton`, and likewise for every Wire macro.
/// Only Wire's own selector is stripped — `@OtherModule::Singleton` is a
/// different module's macro and must NOT match. Whitespace around `::` is
/// collapsed (`@Wire :: Singleton` is legal but unusual). See
/// `MultiModuleComposition.md`.
func wireMacroNameMatches(_ written: String, _ name: String) -> Bool {
    let collapsed = written.filter { !$0.isWhitespace }
    return collapsed == name || collapsed == "Wire::\(name)"
}
