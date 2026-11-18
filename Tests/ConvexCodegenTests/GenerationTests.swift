import ConvexContract
import Foundation
import Testing

@testable import ConvexCodegen

@Suite("Swift generation semantics")
struct GenerationTests {
    typealias J = ContractJSON

    // MARK: Presence and scalars

    @Test func presenceAndNullabilityStayDistinct() throws {
        let json = J.document(
            functions: [
                J.function(
                    "notes:save",
                    kind: "mutation",
                    arguments: [
                        J.field("cursor", J.union(J.null, J.string), optional: true),
                        J.field("limit", J.float64, optional: true),
                        J.field("marker", J.null),
                        J.field("parent", J.union(J.string, J.null)),
                        J.field("silence", J.null, optional: true),
                        J.field("title", J.string),
                    ]
                )
            ]
        )
        let request = try generatedModule(json).required("API.Notes.Save")
        let expected: [(String, SwiftType, Presence)] = [
            ("cursor", .field(.optional(.string)), .optionalNullable),
            ("limit", .optional(.double), .optional),
            ("marker", .convexNull, .required),
            ("parent", .optional(.string), .required),
            ("silence", .field(.convexNull), .optionalNullable),
            ("title", .string, .required),
        ]
        #expect(request.properties.map(\.name) == expected.map { $0.0 })
        for (name, type, presence) in expected {
            #expect(request.property(name)?.type == type, "\(name)")
            #expect(request.property(name)?.presence == presence, "\(name)")
        }
    }

    @Test func dynamicPositionsAbsorbNullAndStayExplicit() throws {
        let json = J.document(
            functions: [
                J.function(
                    "tools:echo",
                    kind: "action",
                    arguments: [
                        J.field("maybe", J.union(J.dynamic, J.null), optional: true),
                        J.field("value", J.dynamic),
                    ],
                    result: J.dynamic
                )
            ]
        )
        let module = try generatedModule(json)
        let request = try module.required("API.Tools.Echo")
        #expect(request.property("maybe")?.type == .field(.convexValue))
        #expect(request.property("value")?.type == .convexValue)
        #expect(request.property("value")?.presence == .required)
        #expect(try module.required("API.Tools.Echo.Output").aliasedType == .convexValue)
    }

    @Test func convexScalarKindsKeepTheirSwiftTypes() throws {
        let json = J.document(
            functions: [
                J.function(
                    "scalars:all",
                    arguments: [
                        J.field("bytes", J.bytes),
                        J.field("committed", #"{"kind": "int64", "semantic": "commitTimestamp"}"#),
                        J.field("count", J.int64),
                        J.field("ratio", J.float64),
                    ]
                )
            ]
        )
        let request = try generatedModule(json).required("API.Scalars.All")
        #expect(request.properties.map(\.type) == [.data, .int64, .int64, .double])
    }

    // MARK: Requests, tables, and names

    @Test func requestsFixKindAddressAndOutput() throws {
        let json = J.document(
            functions: [
                J.function("admin/users:remove", kind: "mutation", result: J.id("users")),
                J.function("health:check"),
                J.function("mail:send", kind: "action"),
            ],
            tables: [J.table("users")]
        )
        let module = try generatedModule(json)
        let remove = try module.required("API.Admin.Users.Remove")
        #expect(
            remove.kind
                == .request(
                    Request(kind: .mutation, functionPath: "admin/users:remove", properties: [])
                )
        )
        #expect(
            try module.required("API.Admin.Users.Remove.Output").aliasedType
                == .documentID(table: QualifiedName(["API", "Tables", "Users"]))
        )
        #expect(try module.required("API.Mail.Send.Output").aliasedType == .convexNull)
        #expect(try module.required("API.Admin").kind == .namespace)
        #expect(try module.required("API.Admin.Users").kind == .namespace)
    }

    @Test func documentSystemFieldsAndAcronymsMapToSwiftNames() throws {
        let json = J.document(
            tables: [
                J.table("channels"),
                J.table(
                    "messages",
                    document: J.object([
                        J.field("channelId", J.id("channels")),
                        J.field("_id", J.id("messages")),
                        J.field("authorUrl", J.string),
                        J.field("_creationTime", J.float64),
                    ])
                ),
            ]
        )
        let document = try generatedModule(json).required("API.Tables.Messages.Document")
        #expect(
            document.properties.map(\.name) == ["creationTime", "id", "authorURL", "channelID"]
        )
        #expect(
            document.properties.map(\.wireName) == [
                "_creationTime", "_id", "authorUrl", "channelId",
            ]
        )
        #expect(
            document.property("channelID")?.type
                == .documentID(table: QualifiedName(["API", "Tables", "Channels"]))
        )
    }

    @Test func storageIDsGetATableMarkerWithoutADocument() throws {
        let json = J.document(
            functions: [
                J.function("files:url", arguments: [J.field("storageId", J.id("_storage"))])
            ]
        )
        let module = try generatedModule(json)
        #expect(try module.required("API.Tables.Storage").kind == .table(wireName: "_storage"))
        #expect(module.declaration(named: "API.Tables.Storage.Document") == nil)
    }

    @Test func nestedPositionsGetStableDerivedNames() throws {
        let tag = J.object([J.field("name", J.string)])
        let json = J.document(
            functions: [
                J.function(
                    "search:run",
                    arguments: [J.field("filter", J.object([J.field("tags", J.array(tag))]))],
                    result: J.union(J.null, J.object([J.field("total", J.float64)]))
                )
            ]
        )
        let module = try generatedModule(json)
        let filter = try module.required("API.Search.Run.Filter")
        #expect(
            filter.property("tags")?.type
                == .array(.named(QualifiedName(["API", "Search", "Run", "Filter", "TagsElement"])))
        )
        #expect(
            try module.required("API.Search.Run.Output").aliasedType
                == .optional(.named(QualifiedName(["API", "Search", "Run", "OutputValue"])))
        )
        #expect(
            try module.required("API.Search.Run.OutputValue").property("total")?.type == .double
        )
    }

    @Test func normalizedNameCollisionsRequireAnOverride() throws {
        let json = J.document(
            functions: [
                J.function(
                    "users:find",
                    arguments: [J.field("user_id", J.string), J.field("userId", J.string)]
                )
            ]
        )
        let diagnostics = try generationDiagnostics(json)
        #expect(diagnostics.map(\.code) == [.nameCollision])
        #expect(diagnostics.first?.path?.description == "functions[users:find].arguments[user_id]")

        let resolved = try generatedModule(
            json,
            names: ["functions[users:find].arguments[user_id]": "legacyUserID"]
        )
        let request = try resolved.required("API.Users.Find")
        #expect(request.properties.map(\.name) == ["userID", "legacyUserID"])
        #expect(request.properties.map(\.wireName) == ["userId", "user_id"])
    }

    @Test func functionsAndModulesCannotShareASwiftName() throws {
        let json = J.document(functions: [
            J.function("messages:list"), J.function("messages/list:recent"),
        ])
        #expect(try generationDiagnostics(json).map(\.code) == [.nameCollision])

        let resolved = try generatedModule(json, names: ["modules[messages/list]": "Listing"])
        #expect(try resolved.required("API.Messages.List").kind != .namespace)
        #expect(try resolved.required("API.Messages.Listing.Recent").kind != .namespace)
    }

    @Test func typeNamesThatDifferOnlyInCaseCollide() throws {
        let json = J.document(types: [("A", J.string), ("B", J.string)])
        let diagnostics = try generationDiagnostics(
            json,
            names: ["types[A]": "Item", "types[B]": "ITEM"]
        )
        #expect(diagnostics.map(\.code) == [.nameCollision])
    }

    @Test func generatedNamespacesAndReservedNamesNeedOverrides() throws {
        let json = J.document(
            functions: [J.function("tables:list", arguments: [J.field("self", J.string)])],
            tables: [J.table("users")]
        )
        let diagnostics = try generationDiagnostics(json)
        #expect(
            Set(diagnostics.compactMap(\.path?.description))
                == ["functions[tables:list]", "functions[tables:list].arguments[self]"]
        )
        let resolved = try generationDiagnostics(
            json,
            names: [
                "modules[tables]": "TableAdmin", "functions[tables:list].arguments[self]": "target",
            ]
        )
        #expect(resolved.isEmpty)
    }

    @Test func unnameableBackendNamesNeedOverrides() throws {
        let json = J.document(types: [("Odd", J.object([J.field("!!", J.string)]))])
        #expect(try generationDiagnostics(json).map(\.code) == [.unnameable])
        #expect(try generationDiagnostics(json, names: ["types[Odd][!!]": "bangs"]).isEmpty)
    }

    @Test func unusedAndInvalidOverridesFail() throws {
        let json = J.document(functions: [J.function("a:b")])
        let unused = try generationDiagnostics(json, names: ["functions[gone:away]": "Away"])
        #expect(unused.map(\.code) == [.unusedNameOverride])
        #expect(unused.first?.file == .configuration)
        let invalid = try generationDiagnostics(json, names: ["functions[a:b]": "not valid"])
        #expect(invalid.map(\.code) == [.invalidName])
    }

    // MARK: Unions and literals

    @Test func discriminatedObjectUnionsDecodeByTheirTag() throws {
        let json = J.document(
            types: [
                (
                    "Event",
                    J.union(
                        J.object([
                            J.field("kind", J.literal(#""created""#)), J.field("id", J.string),
                        ]),
                        J.object([
                            J.field("kind", J.literal(#""deleted""#)),
                            J.field("reason", J.string, optional: true),
                        ])
                    )
                )
            ]
        )
        let event = try #require(try generatedModule(json).required("API.Types.Event").union)
        #expect(event.cases.map(\.name) == ["created", "deleted"])
        #expect(
            event.cases.map(\.payload) == [
                .named(QualifiedName(["API", "Types", "Event", "Created"])),
                .named(QualifiedName(["API", "Types", "Event", "Deleted"])),
            ]
        )
        #expect(
            event.branches == [
                KindBranch(
                    kind: .object,
                    match: .discriminant(
                        field: "kind",
                        branches: [
                            Branch(
                                values: [.string("created")],
                                caseName: "created",
                                decodesPayload: true
                            ),
                            Branch(
                                values: [.string("deleted")],
                                caseName: "deleted",
                                decodesPayload: true
                            ),
                        ]
                    )
                )
            ]
        )
    }

    @Test func wireKindDisjointUnionsBranchByKindAndValue() throws {
        let json = J.document(
            types: [
                (
                    "Value",
                    J.union(
                        J.string,
                        J.float64,
                        J.object([J.field("label", J.string)]),
                        J.literal("true"),
                        J.literal("false")
                    )
                )
            ]
        )
        let union = try #require(try generatedModule(json).required("API.Types.Value").union)
        #expect(union.cases.map(\.name) == ["string", "float64", "object", "true", "false"])
        #expect(
            union.branches == [
                KindBranch(
                    kind: .boolean,
                    match: .values([
                        Branch(values: [.boolean(true)], caseName: "true", decodesPayload: false),
                        Branch(values: [.boolean(false)], caseName: "false", decodesPayload: false),
                    ])
                ),
                KindBranch(kind: .string, match: .single(caseName: "string")),
                KindBranch(kind: .float64, match: .single(caseName: "float64")),
                KindBranch(kind: .object, match: .single(caseName: "object")),
            ]
        )
    }

    @Test(arguments: [
        [ContractJSON.string, ContractJSON.literal(#""a""#)],
        [ContractJSON.id("users"), ContractJSON.string],
        [ContractJSON.array(ContractJSON.string), ContractJSON.tuple(ContractJSON.float64)],
        [
            ContractJSON.record(key: ContractJSON.string, value: ContractJSON.string),
            ContractJSON.object([]),
        ],
        [ContractJSON.literal(#""a""#), ContractJSON.ref("A")],
        [ContractJSON.dynamic, ContractJSON.string],
        [ContractJSON.ref("MaybeText"), ContractJSON.boolean],
        [
            ContractJSON.object([
                ContractJSON.field("kind", ContractJSON.literal(#""a""#), optional: true)
            ]),
            ContractJSON.object([ContractJSON.field("kind", ContractJSON.literal(#""b""#))]),
        ],
        [
            ContractJSON.object([ContractJSON.field("radius", ContractJSON.float64)]),
            ContractJSON.object([ContractJSON.field("width", ContractJSON.float64)]),
        ],
    ])
    func overlappingVariantsFailInsteadOfGuessing(variants: [String]) throws {
        let union = #"{"kind": "union", "variants": [\#(variants.joined(separator: ", "))]}"#
        let json = J.document(
            tables: [J.table("users")],
            types: [
                ("A", J.literal(#""a""#)), ("MaybeText", J.union(J.string, J.null)), ("U", union),
            ]
        )
        let diagnostics = try generationDiagnostics(json)
        #expect(diagnostics.map(\.code) == [.overlappingUnion], "\(diagnostics)")
        #expect(diagnostics.first?.path?.description == "types[U]")
    }

    @Test func literalUnionsBecomeEnumsThatCheckMembership() throws {
        let json = J.document(
            types: [
                ("Level", J.union(J.literal("1"), J.literal("2.5"))),
                (
                    "Mixed",
                    J.union(
                        J.literal(#""auto""#),
                        J.literal("false"),
                        J.literal(#"{"$integer": "AQAAAAAAAAA="}"#)
                    )
                ),
                ("Status", J.union(J.literal(#""active""#), J.literal(#""in_progress""#))),
            ]
        )
        let module = try generatedModule(json)
        let status = try #require(try module.required("API.Types.Status").union)
        #expect(status.isStringLiteralOnly)
        #expect(status.cases.map(\.name) == ["active", "inProgress"])
        #expect(status.cases.map(\.literal) == [.string("active"), .string("in_progress")])

        let level = try #require(try module.required("API.Types.Level").union)
        #expect(level.isLiteralOnly && !level.isStringLiteralOnly)
        #expect(level.cases.map(\.name) == ["number1", "number2_5"])
        #expect(level.branches.map(\.kind) == [.float64])

        let mixed = try #require(try module.required("API.Types.Mixed").union)
        #expect(mixed.cases.map(\.literal) == [.string("auto"), .boolean(false), .int64(1)])
        #expect(mixed.branches.map(\.kind) == [.boolean, .string, .int64])
    }

    @Test func requiredSingleLiteralFieldsStillRequireTheirValue() throws {
        let json = J.document(types: [
            ("Tagged", J.object([J.field("kind", J.literal(#""tagged""#))]))
        ])
        let module = try generatedModule(json)
        let kind = try #require(try module.required("API.Types.Tagged").property("kind"))
        #expect(kind.presence == .required)
        #expect(kind.type == .named(QualifiedName(["API", "Types", "Tagged", "Kind"])))
        let literal = try #require(try module.required("API.Types.Tagged.Kind").union)
        #expect(literal.cases.map(\.literal) == [.string("tagged")])
    }

    // MARK: Collections

    @Test func recordKeysUseStringsIDsOrGeneratedKeyEnums() throws {
        let json = J.document(
            tables: [J.table("users")],
            types: [
                (
                    "Absorbed",
                    J.record(key: J.union(J.string, J.literal(#""a""#)), value: J.boolean)
                ),
                ("ByID", J.record(key: J.id("users"), value: J.string)),
                (
                    "ByLiteral",
                    J.record(key: J.union(J.literal(#""a""#), J.literal(#""b""#)), value: J.boolean)
                ),
                ("ByName", J.record(key: J.string, value: J.float64)),
            ]
        )
        let module = try generatedModule(json)
        let users = QualifiedName(["API", "Tables", "Users"])
        #expect(
            try module.required("API.Types.Absorbed").aliasedType
                == .dictionary(key: .string, value: .bool)
        )
        #expect(
            try module.required("API.Types.ByID").aliasedType
                == .dictionary(key: .documentID(table: users), value: .string)
        )
        #expect(
            try module.required("API.Types.ByLiteral").aliasedType
                == .dictionary(
                    key: .named(QualifiedName(["API", "Types", "ByLiteralKey"])),
                    value: .bool
                )
        )
        #expect(try module.required("API.Types.ByLiteralKey").union?.isStringLiteralOnly == true)
        #expect(
            try module.required("API.Types.ByName").aliasedType
                == .dictionary(key: .string, value: .double)
        )
    }

    @Test func idKeysCannotShareAKeyUnionWithLiterals() throws {
        let json = J.document(
            tables: [J.table("users")],
            types: [
                (
                    "Keys",
                    J.record(key: J.union(J.id("users"), J.literal(#""me""#)), value: J.boolean)
                )
            ]
        )
        #expect(try generationDiagnostics(json).map(\.code) == [.overlappingUnion])
    }

    @Test func tuplesBecomeFixedLengthStructs() throws {
        let json = J.document(types: [("Pair", J.tuple(J.string, J.union(J.null, J.float64)))])
        let pair = try generatedModule(json).required("API.Types.Pair")
        guard case .tuple(let elements) = pair.kind else {
            Issue.record("Expected a tuple, found \(pair.kind)")
            return
        }
        #expect(elements.map(\.name) == ["element0", "element1"])
        #expect(elements.map(\.type) == [.string, .optional(.double)])
    }

    // MARK: Determinism and fixtures

    @Test func outputIsIndependentOfInputOrdering() throws {
        let send = J.function(
            "messages:send",
            kind: "mutation",
            arguments: [J.field("body", J.string), J.field("channelId", J.id("channels"))]
        )
        let list = J.function("messages:list", result: J.array(J.ref("Message")))
        let message = J.object([
            J.field("body", J.string), J.field("_id", J.id("messages")),
            J.field("_creationTime", J.float64),
        ])
        let reordered = J.object([
            J.field("_creationTime", J.float64), J.field("_id", J.id("messages")),
            J.field("body", J.string),
        ])
        let channels = J.table("channels")
        let messages = J.table("messages", document: J.ref("Message"))
        let first = J.document(
            functions: [send, list],
            tables: [messages, channels],
            types: [("Message", message), ("Text", J.string)]
        )
        let second = J.document(
            functions: [list, send],
            tables: [channels, messages],
            types: [("Text", J.string), ("Message", reordered)]
        )
        let generator = SwiftGenerator()
        let firstSource = try generator.generate(from: ContractDocument(data: Data(first.utf8)))
        let secondSource = try generator.generate(from: ContractDocument(data: Data(second.utf8)))
        #expect(firstSource == secondSource)
    }

    @Test func edgeFixtureGeneratesWithItsNameOverride() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let configuration = try GeneratorConfiguration(
            contentsOf: fixtures.appending(path: "convex-swift.json")
        )
        let contract = try ContractDocument(data: Data(contentsOf: configuration.contractURL))
        let module = try SwiftGenerator(configuration: configuration).lower(contract)
        let everything = try module.required("Edge.Misc.Everything")
        #expect(everything.property("ownerIndex")?.wireName == "byOwner")
        #expect(try module.required("Edge.Tables.Storage").kind == .table(wireName: "_storage"))
        #expect(try module.required("Edge.Content.Post.Output").aliasedType == .int64)
    }
}
