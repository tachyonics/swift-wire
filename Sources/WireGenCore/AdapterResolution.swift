// Resolution + validation of adapter-annotation use-sites (iteration 8c/8d).
//
// Classifies each captured use-site against the discovered definitions (so
// non-adapter attributes are dropped), substitutes the definition's register
// signature against the use-site's type arguments, and validates each resulting
// dependency against the resolved binding graph — reusing `matchProducer`, so
// adapter dependencies resolve exactly the way ordinary `@Inject` dependencies
// do. Produces emit-ready registrations plus diagnostics. See
// `Documentation/Notes/AdapterModel.md`.

/// One resolved adapter registration, ready for emission as the
/// post-construction call `<calleeType>._wireRegister(<arguments>)`.
package struct ResolvedAdapterRegistration: Sendable, Equatable {
    /// One emit-ready argument: the parameter label (from the register
    /// signature) and the local name of the matched binding in `_wireBootstrap`.
    package struct Argument: Sendable, Equatable {
        package let label: String?
        package let localName: String

        package init(label: String?, localName: String) {
            self.label = label
            self.localName = localName
        }
    }

    /// The annotated type, qualified — the callee of the `_wireRegister` call.
    package let calleeType: String
    package let phase: AdapterPhase
    package let arguments: [Argument]

    package init(calleeType: String, phase: AdapterPhase, arguments: [Argument]) {
        self.calleeType = calleeType
        self.phase = phase
        self.arguments = arguments
    }
}

/// Resolve adapter use-sites against the discovered definitions and the
/// resolved graph's bindings. A use-site whose annotation name matches no
/// definition is dropped (it's some other library's attribute). For a matching
/// use-site, each register-signature parameter is substituted (`Self` → the
/// annotated type, `$N` → the annotation's Nth type argument, anything else a
/// literal type) and validated against the producer set; the registration is
/// emitted only when every parameter resolves. Missing bindings and
/// duplicate-name definitions become `.error` diagnostics.
///
/// `producers` is the resolved graph's topological order — keyed by identity
/// here so the lookup reuses the exact `matchProducer` the graph validated with.
package func resolveAdapterRegistrations(
    useSites: [AdapterUseSite],
    definitions: [DiscoveredAdapterAnnotation],
    producers: [DiscoveredBinding]
) -> (registrations: [ResolvedAdapterRegistration], diagnostics: [Diagnostic]) {
    let resolvedProducers = Dictionary(
        producers.map { ($0.identity, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let (definitionsByName, definitionDiagnostics) = indexAdapterDefinitions(definitions)

    var registrations: [ResolvedAdapterRegistration] = []
    var diagnostics = definitionDiagnostics
    for useSite in useSites {
        guard let definition = definitionsByName[useSite.annotationName] else { continue }
        let resolved = resolveUseSite(useSite, against: definition, producers: resolvedProducers)
        if let registration = resolved.registration { registrations.append(registration) }
        diagnostics.append(contentsOf: resolved.diagnostics)
    }
    return (registrations, diagnostics.sorted { $0.location < $1.location })
}

/// Index definitions by annotation name. Two definitions sharing a name —
/// conflicting contracts across modules — are an error, and the name is left
/// out of the index so its use-sites stay unresolved (no single contract to
/// apply).
private func indexAdapterDefinitions(
    _ definitions: [DiscoveredAdapterAnnotation]
) -> (byName: [String: DiscoveredAdapterAnnotation], diagnostics: [Diagnostic]) {
    var grouped: [String: [DiscoveredAdapterAnnotation]] = [:]
    for definition in definitions {
        grouped[definition.annotationName, default: []].append(definition)
    }
    var byName: [String: DiscoveredAdapterAnnotation] = [:]
    var diagnostics: [Diagnostic] = []
    for (name, group) in grouped.sorted(by: { $0.key < $1.key }) {
        guard group.count == 1, let only = group.first else {
            for definition in group {
                diagnostics.append(
                    Diagnostic(
                        location: definition.location,
                        message: "adapter annotation '\(name)' is defined more than once",
                        severity: .error
                    )
                )
            }
            continue
        }
        byName[name] = only
    }
    return (byName, diagnostics)
}

/// Substitute and validate one use-site against its definition. Returns the
/// registration when every parameter resolves, plus any diagnostics (a missing
/// binding or an out-of-range type-argument reference, anchored at the use-site).
private func resolveUseSite(
    _ useSite: AdapterUseSite,
    against definition: DiscoveredAdapterAnnotation,
    producers: [BindingIdentity: DiscoveredBinding]
) -> (registration: ResolvedAdapterRegistration?, diagnostics: [Diagnostic]) {
    var arguments: [ResolvedAdapterRegistration.Argument] = []
    var diagnostics: [Diagnostic] = []
    var resolvedAll = true
    for parameter in parseRegisterSignature(definition.registerSignature) {
        guard let concreteType = substitute(parameter.placeholder, in: useSite) else {
            diagnostics.append(
                Diagnostic(
                    location: useSite.location,
                    message:
                        "'@\(useSite.annotationName)' on '\(useSite.annotatedTypeName)' supplies "
                        + "\(useSite.typeArguments.count) type argument(s), but its registration "
                        + "references '\(parameter.placeholder)'",
                    severity: .error
                )
            )
            resolvedAll = false
            continue
        }
        let split = optionalityStripped(canonicalTypeName(concreteType))
        let identity = BindingIdentity(base: split.base, isOptional: split.isOptional, key: nil)
        switch matchProducer(for: identity, in: producers) {
        case .resolved(let producerIdentity):
            let binding = producers[producerIdentity]
            arguments.append(
                ResolvedAdapterRegistration.Argument(
                    label: parameter.label,
                    localName: identifierName(forType: binding?.boundType ?? concreteType, key: binding?.keyIdentifier)
                )
            )
        case .missing:
            diagnostics.append(
                Diagnostic(
                    location: useSite.location,
                    message:
                        "no binding produces '\(identity.displayType)', required by "
                        + "'@\(useSite.annotationName)' on '\(useSite.annotatedTypeName)'",
                    severity: .error
                )
            )
            resolvedAll = false
        }
    }
    guard resolvedAll else { return (nil, diagnostics) }
    return (
        ResolvedAdapterRegistration(
            calleeType: useSite.annotatedQualifiedTypeName,
            phase: definition.phase,
            arguments: arguments
        ),
        diagnostics
    )
}

/// One parameter of a register signature: its call label (if any) and the
/// placeholder/type text to substitute.
private struct SignatureParameter {
    let label: String?
    let placeholder: String
}

/// Parse a register-signature template — `"(instance: Self, router: $0)"` —
/// into its parameters. Commas are split at bracket depth 0 so commas inside
/// generic/collection arguments don't split a parameter; the label is the text
/// before the first `:`, the placeholder the text after.
private func parseRegisterSignature(_ signature: String) -> [SignatureParameter] {
    var inner = trimmed(signature[...])
    if inner.hasPrefix("(") { inner = inner.dropFirst() }
    if inner.hasSuffix(")") { inner = inner.dropLast() }
    guard !trimmed(inner).isEmpty else { return [] }

    return depthAwareSplit(inner, on: ",").map { segment in
        let text = trimmed(segment)
        guard let colon = text.firstIndex(of: ":") else {
            return SignatureParameter(label: nil, placeholder: String(text))
        }
        let label = trimmed(text[..<colon])
        let placeholder = trimmed(text[text.index(after: colon)...])
        return SignatureParameter(
            label: label.isEmpty ? nil : String(label),
            placeholder: String(placeholder)
        )
    }
}

/// Substitute a register-signature placeholder against a use-site: `Self` → the
/// annotated type, `$N` → the annotation's Nth type argument (`nil` when out of
/// range), anything else a literal type returned verbatim.
private func substitute(_ placeholder: String, in useSite: AdapterUseSite) -> String? {
    if placeholder == "Self" {
        return useSite.annotatedTypeName
    }
    if placeholder.hasPrefix("$"), let index = Int(placeholder.dropFirst()) {
        guard index >= 0, index < useSite.typeArguments.count else { return nil }
        return useSite.typeArguments[index]
    }
    return placeholder
}

/// Split a string on `separator` at bracket depth 0, tracking `<>`, `()`, and
/// `[]` nesting so separators inside type arguments are ignored.
private func depthAwareSplit(_ string: Substring, on separator: Character) -> [Substring] {
    var segments: [Substring] = []
    var depth = 0
    var start = string.startIndex
    var index = string.startIndex
    while index < string.endIndex {
        switch string[index] {
        case "<", "(", "[": depth += 1
        case ">", ")", "]": depth -= 1
        case separator where depth == 0:
            segments.append(string[start..<index])
            start = string.index(after: index)
        default: break
        }
        index = string.index(after: index)
    }
    segments.append(string[start...])
    return segments
}

/// Trim leading and trailing whitespace from a substring without Foundation.
private func trimmed(_ string: Substring) -> Substring {
    var result = string
    while let first = result.first, first.isWhitespace { result = result.dropFirst() }
    while let last = result.last, last.isWhitespace { result = result.dropLast() }
    return result
}
