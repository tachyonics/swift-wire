import SwiftSyntax

// Recognition of graph-conformance declarations — `WireGraphConformanceV1`
// declarations. An adapter package declares one to have Wire emit a conformance
// of the generated graph to a protocol it owns, mapping each protocol member to a
// multibinding key's product. Discovered anywhere in source, syntax-only — the
// same discipline as `BindingKeyScanning` / `AdapterAnnotationScanning`.

/// One graph-conformance declaration found in source — a `WireGraphConformanceV1`
/// describing a protocol the generated graph should conform to and how each of
/// its members maps to a multibinding key.
package struct DiscoveredGraphConformance: Sendable, Equatable {
    /// One member mapping: the protocol requirement's name and the canonical text
    /// of the multibinding-key reference whose product witnesses it
    /// (`"HummingbirdKeys.routes"`).
    package struct Member: Sendable, Equatable {
        package let name: String
        package let keyReference: String

        package init(name: String, keyReference: String) {
            self.name = name
            self.keyReference = keyReference
        }
    }

    /// The protocol the graph conforms to — `"HummingbirdComposable"`.
    package let protocolName: String
    package let members: [Member]
    package let location: SourceLocation
    package let originModule: String

    package init(
        protocolName: String,
        members: [Member],
        location: SourceLocation,
        originModule: String
    ) {
        self.protocolName = protocolName
        self.members = members
        self.location = location
        self.originModule = originModule
    }
}

/// Recognise a graph-conformance declaration — a `let`/`static let` whose
/// initialiser is a `WireGraphConformanceV1(...)` call — and capture its protocol
/// and member-to-key mappings. Returns `nil` for any declaration that doesn't
/// construct `WireGraphConformanceV1`, or that has no readable protocol.
func graphConformance(
    from node: VariableDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> DiscoveredGraphConformance? {
    guard node.bindings.count == 1, let binding = node.bindings.first else { return nil }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    guard let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
        let called = call.calledExpression.as(DeclReferenceExprSyntax.self),
        called.baseName.text == "WireGraphConformanceV1"
    else { return nil }

    var protocolName: String?
    var members: [DiscoveredGraphConformance.Member] = []
    for argument in call.arguments {
        switch argument.label?.text {
        case "conformsTo":
            protocolName = conformedProtocolName(from: argument.expression)
        case "members":
            members = conformanceMembers(from: argument.expression)
        default:
            break
        }
    }

    guard let protocolName else { return nil }
    return DiscoveredGraphConformance(
        protocolName: protocolName,
        members: members,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        originModule: module
    )
}

/// The protocol name from a `conformsTo:` metatype expression — `P` for both
/// `P.self` and `(any P).self`. `nil` if it isn't a `.self` metatype.
private func conformedProtocolName(from expression: ExprSyntax) -> String? {
    guard let member = expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "self",
        let base = member.base
    else { return nil }
    var text = base.trimmedDescription
    if text.hasPrefix("(") { text.removeFirst() }
    if text.hasSuffix(")") { text.removeLast() }
    if text.hasPrefix("any ") { text.removeFirst(4) }
    while text.first == " " { text.removeFirst() }
    while text.last == " " { text.removeLast() }
    return text.isEmpty ? nil : text
}

/// The `(name, keyReference)` pairs from a `members:` array literal — each element
/// is a `.init("name", from: KeyRef)` (the callee spelling is ignored; any call
/// with an unlabelled string first argument and a `from:` argument is read).
private func conformanceMembers(from expression: ExprSyntax) -> [DiscoveredGraphConformance.Member] {
    guard let array = expression.as(ArrayExprSyntax.self) else { return [] }
    var result: [DiscoveredGraphConformance.Member] = []
    for element in array.elements {
        guard let call = element.expression.as(FunctionCallExprSyntax.self) else { continue }
        var name: String?
        var keyReference: String?
        for argument in call.arguments {
            if argument.label == nil, name == nil {
                name = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
            } else if argument.label?.text == "from" {
                keyReference = argument.expression.trimmedDescription
            }
        }
        if let name, let keyReference {
            result.append(.init(name: name, keyReference: keyReference))
        }
    }
    return result
}
