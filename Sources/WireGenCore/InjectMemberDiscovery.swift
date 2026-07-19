import SwiftSyntax

/// Output of a one-pass walk over a `@Singleton` / `@Scoped` type's
/// member list — the type's init-time dependencies plus its post-
/// construction member injections, with effect flags propagated
/// from a user-written `@Inject init`.
///
/// Returned as a struct rather than a tuple so the codebase doesn't
/// have to thread a four-element tuple through call sites (the
/// SwiftLint `large_tuple` rule caps tuples at two members anyway).
struct InjectExtractionResult {
    /// Init-time dependencies — `@Inject` properties (delivered via
    /// the macro-synthesised init's parameters) OR an `@Inject`-marked
    /// init's parameter list, with the same priority rule
    /// `SingletonMacro` uses: a user-written `@Inject init` wins
    /// over `@Inject` properties.
    var dependencies: [DependencyParameter] = []
    /// `true` iff a user-written `@Inject init() async` declaration
    /// was found. The macro-synthesised init is always sync.
    var initIsAsync: Bool = false
    /// `true` iff a user-written `@Inject init() throws` declaration
    /// was found. The macro-synthesised init is always non-throwing.
    var initIsThrowing: Bool = false
    /// Post-construction injection points — `@Inject weak var` (sugar
    /// form, `.propertyAssignment` shape) and `@Inject func` (general
    /// form, `.methodCall` shape). Always collected regardless of
    /// which init-time path the type uses.
    var memberInjections: [MemberInjection] = []
    /// Owned-type teardown action from a `@Teardown`-marked method on
    /// this type (member form), or `nil` when none. Recorded in M1 but
    /// inert. At most one per type; a second is a diagnostic.
    var teardown: TeardownAction?
    /// Source-pattern diagnostics raised while walking the type's
    /// members. Caller appends these to the file-level diagnostics
    /// list. Error-severity entries (e.g. `@Inject mutating func`
    /// on a struct) block the build at WireGen time before any
    /// codegen runs.
    var diagnostics: [Diagnostic] = []
}

/// Walk the type's member list once and collect every `@Inject`-
/// related declaration into an `InjectExtractionResult`. Three forms
/// are recognised:
///
/// - `@Inject init(...) [async] [throws]` — init parameters become
///   `.injectInitParameter` deps, effects propagate to the result.
///   Wins over `@Inject` property deps if both are declared.
/// - `@Inject func setX(_ x: T) [async] [throws]` — function
///   parameters become `.injectMethodParameter` deps inside a
///   `.methodCall` member injection. Effects carry to the call site.
/// - `@Inject [weak] var x: T[?]` — non-weak properties become
///   `.injectProperty` init-time deps; weak properties become
///   `.propertyAssignment` member injections with the Optional `?`
///   stripped for graph identity.
///
/// Each form is dispatched to its own helper to keep this function
/// short enough to satisfy the `function_body_length` lint rule and
/// to localise the per-shape extraction logic.
func extractInjectDependencies(
    from members: MemberBlockItemListSyntax,
    hostTypeKind: String,
    sourcePath: String,
    converter: SourceLocationConverter
) -> InjectExtractionResult {
    var result = InjectExtractionResult()
    var propertyDependencies: [DependencyParameter] = []
    for member in members {
        if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
            applyInjectInit(
                initDecl,
                into: &result,
                sourcePath: sourcePath,
                converter: converter
            )
            continue
        }
        if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
            hasAttribute(funcDecl.attributes, named: "Inject")
        {
            applyInjectFunc(
                funcDecl,
                into: &result,
                hostTypeKind: hostTypeKind,
                sourcePath: sourcePath,
                converter: converter
            )
            continue
        }
        if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
            let teardownAttribute = attribute(in: funcDecl.attributes, named: "Teardown")
        {
            applyTeardown(
                funcDecl,
                attribute: teardownAttribute,
                into: &result,
                sourcePath: sourcePath,
                converter: converter
            )
            continue
        }
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        applyInjectVar(
            varDecl,
            into: &result,
            propertyDependencies: &propertyDependencies,
            sourcePath: sourcePath,
            converter: converter
        )
    }
    // Priority rule: a user-written `@Inject init` (captured into
    // `result.dependencies` by `applyInjectInit`) wins over property
    // deps. If no `@Inject init` was found, the accumulated property
    // deps become the binding's init-time list.
    if result.dependencies.isEmpty {
        result.dependencies = propertyDependencies
    }
    return result
}

/// Capture an `@Inject`-marked initialiser's parameter list and
/// effect specifiers. No-op for unmarked inits. Writes through to
/// `result.dependencies` (overwriting any property deps accumulated
/// so far) since the marked init wins the priority rule.
///
/// Also emits a declaration-too-private error when the init is at
/// `fileprivate` or `private` visibility — Wire's generated
/// bootstrap calls the init from a separate file, so the call
/// site can't reach it.
private func applyInjectInit(
    _ initDecl: InitializerDeclSyntax,
    into result: inout InjectExtractionResult,
    sourcePath: String,
    converter: SourceLocationConverter
) {
    guard hasAttribute(initDecl.attributes, named: "Inject") else { return }
    result.dependencies = initDecl.signature.parameterClause.parameters.map { parameter in
        let parameterKey = parameterKeyIdentifier(from: parameter)
        return DependencyParameter(
            name: parameterName(parameter),
            type: parameter.type.trimmedDescription,
            kind: .injectInitParameter,
            location: makeSourceLocation(
                of: parameter.firstName,
                sourcePath: sourcePath,
                converter: converter
            ),
            keyIdentifier: parameterKey
        )
    }
    let effects = functionEffectFlags(initDecl.signature.effectSpecifiers)
    result.initIsAsync = effects.isAsync
    result.initIsThrowing = effects.isThrowing
    let initAccess = accessLevel(from: initDecl.modifiers)
    if !initAccess.isVisibleToGeneratedCode {
        result.diagnostics.append(
            Diagnostic(
                location: makeSourceLocation(
                    of: initDecl.initKeyword,
                    sourcePath: sourcePath,
                    converter: converter
                ),
                message:
                    "@Inject init is '\(initAccess.keyword)' but must be at least 'internal' — Wire's generated bootstrap calls this initialiser from a separate file. Change to 'internal', 'package', or 'public'.",
                severity: .error
            )
        )
    }
}

/// Append a `.methodCall` member injection (and any diagnostic
/// the declaration triggers) to the result. The diagnostic path
/// handles `@Inject mutating func` on a struct host — that
/// combination is structurally broken under Wire's codegen
/// (struct value-copy semantics mean consumers that received the
/// struct via init see the pre-mutation state, while only the
/// `_WireGraph`-stored value reflects the post-init mutation), so
/// we raise an error-severity diagnostic that fails the build at
/// WireGen time before any bad code is emitted.
private func applyInjectFunc(
    _ funcDecl: FunctionDeclSyntax,
    into result: inout InjectExtractionResult,
    hostTypeKind: String,
    sourcePath: String,
    converter: SourceLocationConverter
) {
    let isMutating = funcDecl.modifiers.contains { $0.name.text == "mutating" }
    let funcLocation = makeSourceLocation(
        of: funcDecl.name,
        sourcePath: sourcePath,
        converter: converter
    )
    if isMutating && hostTypeKind == "struct" {
        result.diagnostics.append(
            Diagnostic(
                location: funcLocation,
                message:
                    "'@Inject mutating func' on a struct produces divergent state — consumers that received this binding via init see the pre-mutation value, only the graph-stored value reflects the mutation. Fix: (1) convert to a class so consumers share a reference, (2) drop 'mutating' and manage shared state through an internal reference (e.g. a Mutex<T> stored property), or (3) deliver this dep through @Inject init instead.",
                severity: .error
            )
        )
        // Skip emitting the injection at all — it would produce
        // generated code that won't compile anyway, and adding it
        // would clutter downstream analysis with a member
        // injection the user has been told is invalid.
        return
    }
    let funcAccess = accessLevel(from: funcDecl.modifiers)
    if !funcAccess.isVisibleToGeneratedCode {
        result.diagnostics.append(
            Diagnostic(
                location: funcLocation,
                message:
                    "@Inject func '\(funcDecl.name.text)' is '\(funcAccess.keyword)' but must be at least 'internal' — Wire's generated bootstrap calls this method post-construct and lives in a separate file. Change to 'internal', 'package', or 'public'.",
                notes: [postConstructAsymmetryNote(at: funcLocation)],
                severity: .error
            )
        )
    }
    result.memberInjections.append(
        methodCallInjection(
            from: funcDecl,
            sourcePath: sourcePath,
            converter: converter
        )
    )
}

/// Record a `@Teardown`-marked method as the type's owned-type teardown
/// action (member form), appending any misuse diagnostics. At most one
/// per type; a second is diagnosed and ignored. The recording and
/// diagnostic logic lives in `teardownMethodAction` (TeardownDiscovery);
/// this dispatch helper just threads it into the walk's result.
private func applyTeardown(
    _ funcDecl: FunctionDeclSyntax,
    attribute teardownAttribute: AttributeSyntax,
    into result: inout InjectExtractionResult,
    sourcePath: String,
    converter: SourceLocationConverter
) {
    let (action, diagnostics) = teardownMethodAction(
        from: funcDecl,
        attribute: teardownAttribute,
        existing: result.teardown,
        sourcePath: sourcePath,
        converter: converter
    )
    result.diagnostics.append(contentsOf: diagnostics)
    if let action { result.teardown = action }
}

/// Note explaining why post-construct delivery patterns
/// (`@Inject weak var`, `@Inject func`, `@Teardown`) must be at least
/// `internal` while constructor-injected `@Inject var` / `@Inject let`
/// can be `private`. The asymmetry is easy to miss; the note pre-empts
/// the inevitable "but my @Inject private var works fine!" reaction.
/// Shared with `TeardownDiscovery`'s too-private teardown diagnostic.
func postConstructAsymmetryNote(at location: SourceLocation) -> Diagnostic.Note {
    Diagnostic.Note(
        location: location,
        message:
            "'@Inject var' / '@Inject let' (non-weak) can be 'private' because the macro generates the init within the host type's scope; only post-construct delivery patterns (weak, @Inject func, @Teardown) need broader visibility because the bootstrap references them from a separate file."
    )
}

/// Build a `.methodCall` member injection from an `@Inject func`
/// declaration. Each parameter resolves through the graph the same
/// way as init params; codegen emits the call after the
/// construction sequence with `[try] [await]` driven by the
/// function's effect specifiers.
private func methodCallInjection(
    from funcDecl: FunctionDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> MemberInjection {
    let parameters = funcDecl.signature.parameterClause.parameters.map {
        parameter -> DependencyParameter in
        let parameterKey = attribute(in: parameter.attributes, named: "Inject")
            .flatMap { keyIdentifier(from: $0) }
        return DependencyParameter(
            name: parameterName(parameter),
            type: parameter.type.trimmedDescription,
            kind: .injectMethodParameter,
            location: makeSourceLocation(
                of: parameter.firstName,
                sourcePath: sourcePath,
                converter: converter
            ),
            keyIdentifier: parameterKey
        )
    }
    let effects = functionEffectFlags(funcDecl.signature.effectSpecifiers)
    return MemberInjection(
        shape: .methodCall(methodName: funcDecl.name.text),
        parameters: parameters,
        isAsync: effects.isAsync,
        isThrowing: effects.isThrowing,
        location: makeSourceLocation(
            of: funcDecl.name,
            sourcePath: sourcePath,
            converter: converter
        ),
        accessLevel: accessLevel(from: funcDecl.modifiers)
    )
}

/// Dispatch an `@Inject var`/`let` declaration:
/// - `weak var` → a `.propertyAssignment` member injection (post-
///   construct delivery — the cycle-breaker).
/// - `weak let` → an init-time `.injectProperty` dependency (delivered
///   at construction, so a cycle *participant*, not a breaker), with a
///   warning to that effect.
/// - non-weak → an init-time `.injectProperty` dependency.
///
/// Weak storage is forced to Optional by Swift; the declared type is
/// kept as-is and the graph resolver promotes `T?`/`T!` against the
/// producer's `T` binding. See `OptionalMatchingAndCycles.md`.
private func applyInjectVar(
    _ varDecl: VariableDeclSyntax,
    into result: inout InjectExtractionResult,
    propertyDependencies: inout [DependencyParameter],
    sourcePath: String,
    converter: SourceLocationConverter
) {
    guard let injectAttribute = attribute(in: varDecl.attributes, named: "Inject") else { return }
    let propertyKey = keyIdentifier(from: injectAttribute)
    let isWeak = varDecl.modifiers.contains { $0.name.text == "weak" }
    let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)
    let isUnowned = varDecl.modifiers.contains { $0.name.text == "unowned" }
    for binding in varDecl.bindings {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
        guard let typeAnnotation = binding.typeAnnotation else { continue }
        let location = makeSourceLocation(
            of: pattern.identifier,
            sourcePath: sourcePath,
            converter: converter
        )
        if isWeak && !isLet {
            appendWeakVarMemberInjection(
                propertyName: pattern.identifier.text,
                typeAnnotation: typeAnnotation.type,
                propertyKey: propertyKey,
                location: location,
                modifiers: varDecl.modifiers,
                into: &result
            )
        } else {
            // Owning property, `weak let`, or `unowned …` — all init-time,
            // constructor-injected dependencies. The two non-owning forms
            // are flagged so that IF one closes a cycle the cyclic-
            // dependency error can point at it (converting to `weak var`
            // breaks the cycle post-construct). No blanket warning: an
            // acyclic `weak let` / `unowned` is a legitimate non-owning
            // reference (`weak let` is SE-0481; `unowned` is non-optional,
            // for a target known to outlive the host). `unowned` can't be
            // a breaker — non-optional storage must be initialised at init,
            // so it can't be deferred post-construct. See
            // OptionalMatchingAndCycles.md.
            let nonOwningForm: NonOwningInitForm? = isWeak ? .weakLet : (isUnowned ? .unowned : nil)
            propertyDependencies.append(
                DependencyParameter(
                    name: pattern.identifier.text,
                    type: typeAnnotation.type.trimmedDescription,
                    kind: .injectProperty,
                    location: location,
                    keyIdentifier: propertyKey,
                    nonOwningInitForm: nonOwningForm
                )
            )
        }
    }
}

/// Emit the `weak var` post-construct member injection (the cycle-break
/// sugar) plus the declaration-too-private / setter-restriction errors it
/// can trigger: the bootstrap assigns to the property from a separate
/// file post-construct, so it must be reachable for writing.
private func appendWeakVarMemberInjection(
    propertyName: String,
    typeAnnotation: TypeSyntax,
    propertyKey: String?,
    location: SourceLocation,
    modifiers: DeclModifierListSyntax,
    into result: inout InjectExtractionResult
) {
    let weakAccess = accessLevel(from: modifiers)
    let weakSetter = setterAccessLevel(from: modifiers)
    if !weakAccess.isVisibleToGeneratedCode {
        result.diagnostics.append(
            Diagnostic(
                location: location,
                message:
                    "@Inject weak var '\(propertyName)' is '\(weakAccess.keyword)' but must be at least 'internal' — Wire's generated bootstrap assigns to this property post-construct and lives in a separate file. Change to 'internal', 'package', or 'public'.",
                notes: [postConstructAsymmetryNote(at: location)],
                severity: .error
            )
        )
    }
    if let setter = weakSetter, !setter.isVisibleToGeneratedCode {
        result.diagnostics.append(
            Diagnostic(
                location: location,
                message:
                    "@Inject weak var '\(propertyName)' setter is '\(setter.keyword)(set)' but must be at least 'internal' — Wire's generated bootstrap assigns to this property post-construct and lives in a separate file. The setter restriction blocks Wire's write even though the property's read access is otherwise reachable.",
                notes: [
                    Diagnostic.Note(
                        location: location,
                        message:
                            "Drop the setter restriction to inherit the property's read access, or use 'internal(set)' / higher if a narrower setter is required."
                    )
                ],
                severity: .error
            )
        )
    }
    result.memberInjections.append(
        propertyAssignmentInjection(
            propertyName: propertyName,
            typeAnnotation: typeAnnotation,
            propertyKey: propertyKey,
            location: location,
            accessLevel: weakAccess,
            setterAccessLevel: weakSetter
        )
    )
}

/// Build a `.propertyAssignment` member injection from an `@Inject
/// weak var x: T?` (or `T!`) binding. The parameter keeps the full
/// declared optional type; the graph resolver promotes it against the
/// producer's `T` binding (asymmetric optional promotion — see
/// `OptionalMatchingAndCycles.md`). The storage shape on the consumer's
/// class stays `T?` — Swift's requirement for weak.
private func propertyAssignmentInjection(
    propertyName: String,
    typeAnnotation: TypeSyntax,
    propertyKey: String?,
    location: SourceLocation,
    accessLevel: AccessLevel,
    setterAccessLevel: AccessLevel?
) -> MemberInjection {
    let parameter = DependencyParameter(
        name: nil,
        type: typeAnnotation.trimmedDescription,
        kind: .injectMethodParameter,
        location: location,
        keyIdentifier: propertyKey
    )
    return MemberInjection(
        shape: .propertyAssignment(propertyName: propertyName),
        parameters: [parameter],
        location: location,
        accessLevel: accessLevel,
        setterAccessLevel: setterAccessLevel
    )
}
