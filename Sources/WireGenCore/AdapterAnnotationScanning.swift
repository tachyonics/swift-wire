import SwiftSyntax

// Recognition of adapter-annotation definitions — `WireAdapterAnnotationV1`
// declarations. An adapter package declares one per annotation it publishes
// (e.g. `@RoutedBy`); the definition tells Wire what the annotation's macro
// generates, so the build plugin can validate the annotation's dependencies
// and emit registration calls without expanding the macro.
//
// Discovered anywhere in source, syntax-only — the same discipline as
// `BindingKeyScanning`. In M1 a consumer re-parses its Wire-aware
// dependencies' sources, so an adapter package's definitions reach WireGen
// without a manifest file; the generated manifest is M6a. See
// `MultiModuleComposition.md`.

/// Where an adapter annotation attaches. M1: type-level only.
package enum AdapterForm: Sendable, Equatable {
    case typeLevel
}

/// One adapter-annotation definition found in source — a
/// `WireAdapterAnnotationV1` declaration describing an annotation the module
/// publishes.
package struct DiscoveredAdapterAnnotation: Sendable, Equatable {
    /// The attribute spelling without the leading `@` — `"RoutedBy"`. Matches
    /// use-sites to this definition.
    package let annotationName: String
    package let form: AdapterForm
    /// The generated `_wireRegister` parameter template — e.g.
    /// `"(instance: Self, router: $0)"`. `Self` is the annotated type, `$0`
    /// the annotation's first type argument, any other token a literal type.
    package let registerSignature: String
    package let location: SourceLocation
    package let originModule: String

    package init(
        annotationName: String,
        form: AdapterForm,
        registerSignature: String,
        location: SourceLocation,
        originModule: String
    ) {
        self.annotationName = annotationName
        self.form = form
        self.registerSignature = registerSignature
        self.location = location
        self.originModule = originModule
    }
}

/// Recognise an adapter-annotation definition — a `let`/`static let` whose
/// initialiser is a `WireAdapterAnnotationV1(...)` call — and capture its
/// fields. Returns `nil` for any declaration that doesn't construct
/// `WireAdapterAnnotationV1`, or whose `form` names an unknown case.
func adapterAnnotation(
    from node: VariableDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> DiscoveredAdapterAnnotation? {
    guard node.bindings.count == 1, let binding = node.bindings.first else { return nil }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    guard let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
        let called = call.calledExpression.as(DeclReferenceExprSyntax.self),
        called.baseName.text == "WireAdapterAnnotationV1"
    else { return nil }

    var annotationName: String?
    var form: AdapterForm?
    var registerSignature: String?
    for argument in call.arguments {
        switch argument.label?.text {
        case "annotation":
            annotationName = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        case "form":
            form = adapterForm(from: argument.expression)
        case "registerSignature":
            registerSignature = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        default:
            break
        }
    }

    guard let annotationName, let form, let registerSignature else { return nil }

    return DiscoveredAdapterAnnotation(
        annotationName: annotationName,
        form: form,
        registerSignature: registerSignature,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        originModule: module
    )
}

/// The `AdapterForm` named by a `.case` member-access expression, or `nil`
/// for an unknown case.
private func adapterForm(from expression: ExprSyntax) -> AdapterForm? {
    switch expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
    case "typeLevel": return .typeLevel
    default: return nil
    }
}
