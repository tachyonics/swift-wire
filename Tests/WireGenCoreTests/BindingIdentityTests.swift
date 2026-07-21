import Testing

@testable import WireGenCore

/// Canonicalisation of a type expression into a graph slot: whitespace is
/// stripped and protocol-composition members are sorted, so the spellings Swift
/// treats as one type resolve against each other.
@Suite("Binding identity canonicalisation")
struct BindingIdentityTests {

    // MARK: - Whitespace

    @Test func stripsWhitespaceInGenericArguments() {
        #expect(canonicalTypeName("Router<X, Y>") == "Router<X,Y>")
        #expect(canonicalTypeName("Dictionary<String, [Int]>") == "Dictionary<String,[Int]>")
    }

    @Test func leavesAFunctionTypeIntact() {
        // The `>` of the arrow doesn't close a generic argument list.
        #expect(canonicalTypeName("(Int) -> String") == "(Int)->String")
    }

    // MARK: - Composition ordering

    @Test func sortsCompositionMembers() {
        #expect(canonicalTypeName("DBTable & Sendable") == canonicalTypeName("Sendable & DBTable"))
        #expect(canonicalTypeName("Sendable & DBTable") == "DBTable&Sendable")
    }

    @Test func keepsTheOpaqueQualifierLeading() {
        #expect(canonicalTypeName("some Sendable & DBTable") == "someDBTable&Sendable")
        #expect(canonicalTypeName("any Sendable & DBTable") == "anyDBTable&Sendable")
    }

    @Test func doesNotMistakeATypeNameForAQualifier() {
        // `someThing` is a type, not `some Thing`.
        #expect(canonicalTypeName("someThing") == "someThing")
        #expect(canonicalTypeName("anything & Zed") == "Zed&anything")
    }

    @Test func doesNotSortANestedComposition() {
        // Only depth-0 members are the composition; a generic argument stays as written.
        #expect(canonicalTypeName("Box<B & A>") == "Box<B&A>")
    }

    @Test func doesNotSortAParenthesisedComposition() {
        // `(B & A)?` is one optional member, and `optionalityStripped` still sees the `?`.
        #expect(canonicalTypeName("(B & A)?") == "(B&A)?")
        #expect(optionalityStripped(canonicalTypeName("(B & A)?")).isOptional)
    }

    // MARK: - Resolution

    @Test func bridgesAReorderedConstraintToTheSameIdentity() {
        // The producer declares `some DBTable & Sendable`; the consumer's parameter is
        // constrained in the other order. One type to Swift, so one graph slot.
        let consumer = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Repository",
                typeKind: "struct",
                genericParameterNames: ["Table"],
                genericParameterConstraints: ["Table": "Sendable & DBTable"],
                dependencies: [
                    DependencyParameter(
                        name: "table",
                        type: "Table",
                        kind: .injectInitParameter,
                        location: mockLocation("R.swift")
                    )
                ],
                location: mockLocation("R.swift"),
                originModule: testModule
            )
        )
        let dependency = DependencyParameter(
            name: "table",
            type: "Table",
            kind: .injectInitParameter,
            location: mockLocation("R.swift")
        )
        let producerIdentity = BindingIdentity(
            base: canonicalTypeName("some DBTable & Sendable"),
            isOptional: false,
            key: nil
        )
        #expect(bridgedDependencyIdentity(dependency, in: consumer) == producerIdentity)
    }
}
