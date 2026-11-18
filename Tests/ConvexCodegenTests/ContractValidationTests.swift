import ConvexContract
import Foundation
import Testing

@Suite("Contract validation")
struct ContractValidationTests {
    typealias J = ContractJSON

    @Test func unsupportedFormatVersionIsReportedAloneBeforeOtherProblems() {
        let json = J.document(
            functions: [J.function("a:b", result: #"{"kind":"mystery"}"#)],
            formatVersion: "2"
        )
        let diagnostics = contractDiagnostics(json)
        #expect(diagnostics.map(\.code) == [.unsupportedFormatVersion])
    }

    @Test func unknownShapeKindReportsTheFunctionPath() throws {
        let json = J.document(functions: [
            J.function("messages:list", result: #"{"kind":"bigdecimal"}"#)
        ])
        let diagnostic = try #require(contractDiagnostics(json).first)
        #expect(diagnostic.code == .unknownShapeKind)
        #expect(diagnostic.path?.description == "functions[messages:list].result")
    }

    @Test func danglingReferencesAndUnknownTablesFail() {
        let json = J.document(
            functions: [
                J.function(
                    "messages:get",
                    arguments: [J.field("id", J.id("messages"))],
                    result: J.ref("Message")
                )
            ]
        )
        let diagnostics = contractDiagnostics(json)
        #expect(
            Set(diagnostics.map(\.code)) == [.danglingReference, .unknownTable],
            "\(diagnostics)"
        )
        #expect(
            diagnostics.contains {
                $0.code == .unknownTable
                    && $0.path?.description == "functions[messages:get].arguments[id]"
            }
        )
    }

    @Test func storageIDsNeedNoTableEntry() {
        let json = J.document(
            functions: [
                J.function("files:url", arguments: [J.field("storageId", J.id("_storage"))])
            ]
        )
        #expect(contractDiagnostics(json).isEmpty)
    }

    @Test func duplicateFunctionsTablesTypesAndFieldsFail() {
        let object = J.object([J.field("a", J.string), J.field("a", J.float64)])
        let json = """
            {"formatVersion": 1,
             "provenance": {"exporterVersion": "t", "convexVersion": "t", "typescriptVersion": "t",
                            "sourceHash": "\(String(repeating: "0", count: 64))"},
             "functions": [\(J.function("a:b")), \(J.function("a:b"))],
             "tables": [\(J.table("t")), \(J.table("t"))],
             "types": {"T": \(object), "T": \(J.string)}}
            """
        let codes = Set(contractDiagnostics(json).map(\.code))
        #expect(codes == [.duplicateFunction, .duplicateTable, .duplicateType, .duplicateField])
    }

    @Test func recursiveNamedTypesFailOncePerCycle() {
        let json = J.document(
            types: [
                ("Node", J.object([J.field("next", J.ref("Link"))])),
                ("Link", J.union(J.null, J.ref("Node"))),
                ("SelfList", J.array(J.ref("SelfList"))),
            ]
        )
        let diagnostics = contractDiagnostics(json).filter { $0.code == .recursiveReference }
        #expect(
            diagnostics.compactMap(\.path?.description).sorted() == [
                "types[Link]", "types[SelfList]",
            ]
        )
    }

    @Test(arguments: [
        #"{"$integer": "AQ=="}"#,
        #"{"$integer": "AQAAAAAAAAA"}"#,
        #"{"$integer": 1}"#,
        #"{"$float": "AAAAAAAA8D8="}"#,
        "1e400",
        "null",
        "[1]",
    ])
    func invalidLiteralsFail(value: String) {
        let json = J.document(types: [("L", J.literal(value))])
        #expect(contractDiagnostics(json).map(\.code) == [.invalidLiteral])
    }

    @Test func int64LiteralEnvelopesDecodeLittleEndian() throws {
        let json = J.document(types: [("Min", J.literal(#"{"$integer": "AAAAAAAAAIA="}"#))])
        let contract = try ContractDocument(data: Data(json.utf8))
        #expect(contract.types["Min"] == .literal(.int64(.min)))
    }

    @Test func recordKeysMustBeStringsIDsOrStringLiterals() {
        let json = J.document(
            tables: [J.table("users")],
            types: [
                (
                    "Good",
                    J.record(
                        key: J.union(J.id("users"), J.literal(#""a""#), J.ref("Key")),
                        value: J.string
                    )
                ),
                ("Key", J.string),
                ("Numeric", J.record(key: J.float64, value: J.string)),
                ("NumericLiteral", J.record(key: J.literal("1"), value: J.string)),
            ]
        )
        let paths = contractDiagnostics(json).filter { $0.code == .invalidRecordKey }.compactMap(
            \.path?.description
        )
        #expect(paths.sorted() == ["types[NumericLiteral].key", "types[Numeric].key"])
    }

    @Test func unexpectedMembersAndMissingMembersFail() {
        let json = J.document(
            types: [
                ("Extra", #"{"kind": "string", "nullable": true}"#),
                ("Missing", #"{"kind": "array"}"#),
                ("Semantic", #"{"kind": "int64", "semantic": "timestamp"}"#),
            ]
        )
        let codes = contractDiagnostics(json).map(\.code)
        #expect(Set(codes) == [.unexpectedKey, .missingKey, .invalidValue])
    }

    @Test func emptyUnionsAndNonObjectArgumentsFail() {
        let json = J.document(
            functions: [
                #"{"path": "a:b", "module": ["a"], "name": "b", "kind": "query", "arguments": {"kind": "string"}, "#
                    + #""result": {"kind": "union", "variants": []}, "typeSource": "inferred"}"#
            ]
        )
        #expect(Set(contractDiagnostics(json).map(\.code)) == [.invalidValue, .emptyUnion])
    }

    @Test func syntaxErrorsCarryTheirLocation() {
        let diagnostics = contractDiagnostics("{\n  \"formatVersion\": 1,\n  \"functions\": [,]\n}")
        #expect(diagnostics.map(\.code) == [.syntax])
        #expect(diagnostics.first?.location == TextLocation(line: 3, column: 17))
    }

    @Test func diagnosticsCarryJSONLocationAndBackendSource() throws {
        let json = J.document(
            functions: [
                J.function(
                    "messages:list",
                    result: J.ref("Missing"),
                    source: #"{"file": "convex/messages.ts", "line": 7}"#
                )
            ]
        )
        let diagnostic = try #require(contractDiagnostics(json).first)
        #expect(diagnostic.source == SourceLocation(file: "convex/messages.ts", line: 7))
        #expect(diagnostic.location != nil)
    }

    @Test func absoluteSourcePathsAreRejected() {
        let json = J.document(
            functions: [J.function("a:b", source: #"{"file": "/Users/me/convex/a.ts", "line": 1}"#)]
        )
        #expect(contractDiagnostics(json).map(\.code) == [.invalidValue])
    }

    @Test func validContractsSortFunctionsAndTables() throws {
        let json = J.document(
            functions: [J.function("b:z"), J.function("a:y")],
            tables: [
                J.table("zebras"), J.table("ants"),
            ]
        )
        let contract = try ContractDocument(data: Data(json.utf8))
        #expect(contract.functions.map(\.path) == ["a:y", "b:z"])
        #expect(contract.tables.map(\.name) == ["ants", "zebras"])
    }
}
