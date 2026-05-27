import SwiftSyntax

/// If `type` is a `Lazy<T>` instantiation, return `(innerTypeText:
/// "T", isLazyWrapped: true)`. Otherwise return the type's text
/// unchanged with `isLazyWrapped: false`.
///
/// Wire treats `Lazy<T>` as a *wrapper marker* in dependency
/// positions: the consumer is asking for a Lazy-wrapped view of
/// `T`, but the graph identity (the binding that needs to exist,
/// the cycle/missing-binding/cross-scope checks) operates on `T`.
/// Discovery unwraps here so downstream stages see the inner type.
///
/// Recognition is **syntactic, not symbolic**. Any
/// `IdentifierTypeSyntax` named `Lazy` with one generic argument
/// matches — whether it resolves to `Wire.Lazy<T>`, a user's own
/// `Lazy<T>` from a different module, or something else by that
/// name. The pragmatic compromise: a user with a colliding type
/// name should disambiguate at the import / use site (or rename),
/// since the wrapper recognition is a Wire-DI contract feature
/// and the framework can't infer module qualification from
/// SwiftSyntax alone. Qualified forms like `Wire.Lazy<T>` (a
/// `MemberTypeSyntax`) aren't matched today — users referencing
/// Wire's Lazy through a qualified type name would need to
/// rewrite as the unqualified `Lazy<T>`; we'll extend this if a
/// real adopter case forces it.
///
/// Nested wrapping (`Lazy<Lazy<T>>`) is *not* recursively
/// unwrapped — the inner type stays `Lazy<T>`, and Wire treats it
/// as a binding of type `Lazy<T>`. This matches the rare-edge-
/// case posture: if a user writes `Lazy<Lazy<T>>` they probably
/// mean "a Lazy whose value is itself a Lazy," not "double-defer
/// T." If the latter becomes a real pattern, recursion lands
/// here.
///
/// `Lazy<T>` appearing inside another generic (`Box<Lazy<T>>`,
/// `[Lazy<T>]`, `Optional<Lazy<T>>`) doesn't match either — the
/// outer type isn't `Lazy`. The dep's type stays the wrapper
/// shape verbatim, and the graph treats it as a binding of that
/// shape.
func unwrapLazyType(_ type: TypeSyntax) -> (typeText: String, isLazyWrapped: Bool) {
    guard let identifier = type.as(IdentifierTypeSyntax.self),
        identifier.name.text == "Lazy",
        let genericArgs = identifier.genericArgumentClause,
        genericArgs.arguments.count == 1,
        let innerArg = genericArgs.arguments.first?.argument
    else {
        return (type.trimmedDescription, false)
    }
    return (innerArg.trimmedDescription, true)
}
