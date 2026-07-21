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

    // MARK: - Qualifier promotion (rule 3)

    /// A producer set holding exactly the given bound types, keyed by identity.
    private func producers(_ boundTypes: String...) -> [BindingIdentity: DiscoveredBinding] {
        var result: [BindingIdentity: DiscoveredBinding] = [:]
        for boundType in boundTypes {
            let binding = DiscoveredBinding.scopeBound(
                DiscoveredScopeBoundType(
                    typeName: "Impl",
                    typeKind: "struct",
                    genericParameterNames: [],
                    explicitIdentity: boundType.hasPrefix("some ")
                        ? String(boundType.dropFirst("some ".count)) : nil,
                    dependencies: [],
                    location: mockLocation("P.swift"),
                    originModule: testModule
                )
            )
            result[identity(boundType)] = binding
        }
        return result
    }

    private func identity(_ type: String, key: String? = nil) -> BindingIdentity {
        let components = identityComponents(type)
        return BindingIdentity(
            qualifier: components.qualifier,
            base: components.base,
            isOptional: components.isOptional,
            key: key
        )
    }

    @Test func anyConsumerBorrowsTheSomeProducer() {
        let match = matchProducer(for: identity("any Logger"), in: producers("some Logger"))
        #expect(match == .resolved(identity("some Logger")))
    }

    @Test func someConsumerNeverBorrowsTheAnyProducer() {
        // One-directional: `any P` has erased the single underlying type `some P` needs.
        let match = matchProducer(for: identity("some Logger"), in: producers("any Logger"))
        #expect(match == .missing(nil))
    }

    @Test func anExactAnyProducerWinsOverThePromotion() {
        // Exact-first ordering, asserted at the matcher. The graph rejects this
        // producer set upstream as a duplicate binding (see
        // `someAndAnyProducersForOneProtocolAreDuplicates`), so the case can't
        // reach a real codegen run — the ordering is asserted here so promotion
        // can never silently outrank an exact match if that rule ever loosens.
        let match = matchProducer(
            for: identity("any Logger"),
            in: producers("any Logger", "some Logger")
        )
        #expect(match == .resolved(identity("any Logger")))
    }

    @Test func promotionRespectsKeys() {
        // Keys partition the binding space — an unkeyed `some P` can't feed a keyed `any P`.
        let keyed = identity("any Logger", key: "Log.primary")
        #expect(matchProducer(for: keyed, in: producers("some Logger")) == .missing(nil))
    }

    @Test func optionalAndExistentialPromotionsCompose() {
        // `any P?` reaches a non-optional `some P` producer through both promotions.
        let match = matchProducer(for: identity("any Logger?"), in: producers("some Logger"))
        #expect(match == .resolved(identity("some Logger")))
    }

    @Test func aConcreteProducerNeverSatisfiesAnExistential() {
        // The line that keeps this from becoming conformance search: `Logger` is
        // a different identity from `any Logger`, promotion or not.
        #expect(matchProducer(for: identity("any Logger"), in: producers("Logger")) == .missing(nil))
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
        let producer = identityComponents("some DBTable & Sendable")
        let producerIdentity = BindingIdentity(
            qualifier: producer.qualifier,
            base: producer.base,
            isOptional: producer.isOptional,
            key: nil
        )
        #expect(bridgedDependencyIdentity(dependency, in: consumer) == producerIdentity)
        #expect(producerIdentity.displayType == "someDBTable&Sendable")
    }
}
