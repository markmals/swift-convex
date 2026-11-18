import ConvexContract
import Foundation
import Testing

@testable import ConvexCodegen

@Suite("Contract boundary regressions")
struct BoundaryValidationTests {
    typealias J = ContractJSON

    @Test func wildcardCannotNameSwiftDeclarations() throws {
        let json = J.document(functions: [J.function("notes:list")])
        #expect(throws: ContractError.self) { try generatedModule(json, namespace: "_") }
        let diagnostics = try generationDiagnostics(json, names: ["functions[notes:list]": "_"])
        #expect(diagnostics.map(\.code) == [.invalidName])
    }

    @Test(arguments: [
        J.string,
        J.object([]),
        J.object([J.field("_id", J.string), J.field("_creationTime", J.float64)]),
        J.object([
            J.field("_id", J.id("notes"), optional: true), J.field("_creationTime", J.float64),
        ]),
        J.object([J.field("_id", J.id("notes")), J.field("_creationTime", J.int64)]),
        J.object([
            J.field("_id", J.id("notes")), J.field("_creationTime", J.float64, optional: true),
        ]),
    ])
    func tableDocumentsRequireSystemFields(_ shape: String) {
        let diagnostics = contractDiagnostics(
            J.document(tables: [J.table("notes", document: shape)])
        )
        #expect(diagnostics.contains { $0.code == .invalidValue })
    }

    @Test func tableDocumentCannotBorrowAnotherTablesID() {
        let wrong = J.object([J.field("_id", J.id("other")), J.field("_creationTime", J.float64)])
        let valid = J.object([J.field("_id", J.id("other")), J.field("_creationTime", J.float64)])
        let diagnostics = contractDiagnostics(
            J.document(tables: [
                J.table("notes", document: wrong), J.table("other", document: valid),
            ])
        )
        #expect(
            diagnostics.contains {
                $0.code == .invalidValue && $0.path?.description == "tables[notes].document[_id]"
            }
        )
    }

    @Test func documentReferencesAndUnionVariantsAreValidated() {
        let valid = J.object([J.field("_id", J.id("notes")), J.field("_creationTime", J.float64)])
        let invalid = J.document(
            tables: [J.table("notes", document: J.ref("Note"))],
            types: [("Note", J.union(valid, J.string))]
        )
        #expect(contractDiagnostics(invalid).contains { $0.code == .invalidValue })
        #expect(
            contractDiagnostics(
                J.document(
                    tables: [J.table("notes", document: J.ref("Note"))],
                    types: [("Note", valid)]
                )
            ).isEmpty
        )
        #expect(
            contractDiagnostics(J.document(tables: [J.table("notes", document: J.dynamic)])).isEmpty
        )
    }
}
