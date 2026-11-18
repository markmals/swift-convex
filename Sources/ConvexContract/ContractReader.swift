import Foundation

/// Converts parsed JSON into a validated ``ContractDocument``, collecting every problem it finds.
struct ContractReader {
    private var diagnostics: [ContractDiagnostic] = []
    private var locations: [ContractPath: TextLocation] = [:]
    private var source: SourceLocation?

    private static let documentKeys: Set = [
        "formatVersion", "provenance", "functions", "tables", "types",
    ]
    private static let provenanceKeys = [
        "convexVersion", "exporterVersion", "sourceHash", "typescriptVersion",
    ]
    private static let functionKeys: Set = [
        "path", "module", "name", "kind", "arguments", "result", "typeSource", "source",
    ]
    private static let functionRequiredKeys = [
        "arguments", "kind", "module", "name", "path", "result", "typeSource",
    ]

    mutating func read(_ root: JSONNode) throws(ContractError) -> ContractDocument {
        let rootPath = ContractPath()
        guard case .object(let rootMembers) = root.value else {
            throw ContractError(diagnostics: [
                ContractDiagnostic(
                    code: .invalidValue,
                    message:
                        "Expected the contract to be an object, found \(root.value.kindDescription).",
                    location: root.location
                )
            ])
        }
        try checkFormatVersion(rootMembers, location: root.location)

        let members = objectMembers(
            of: root,
            at: rootPath,
            allowed: Self.documentKeys,
            required: ["formatVersion", "functions", "provenance", "tables", "types"]
        )
        let provenance = members?["provenance"].flatMap { readProvenance($0) }
        let types = members?["types"].map { readTypes($0) } ?? [:]
        let tables = members?["tables"].map { readTables($0) } ?? []
        let functions = members?["functions"].map { readFunctions($0) } ?? []

        validateSemantics(functions: functions, tables: tables, types: types)

        guard diagnostics.isEmpty, let provenance else {
            throw ContractError(diagnostics: diagnostics.sortedForReport())
        }
        return ContractDocument(
            provenance: provenance,
            functions: functions.map(\.function).sorted { $0.path < $1.path },
            tables: tables.map(\.table).sorted { $0.name < $1.name },
            types: types,
            locations: locations
        )
    }

    // MARK: Document structure

    private func checkFormatVersion(_ members: [JSONMember], location: TextLocation)
        throws(ContractError)
    {
        guard let member = members.first(where: { $0.key == "formatVersion" }) else {
            throw ContractError(diagnostics: [
                ContractDiagnostic(
                    code: .unsupportedFormatVersion,
                    message:
                        "The contract has no `formatVersion`; this generator reads format version 1.",
                    location: location
                )
            ])
        }
        guard case .number(let lexeme) = member.value.value,
            Int(lexeme) == ContractDocument.supportedFormatVersion
        else {
            throw ContractError(diagnostics: [
                ContractDiagnostic(
                    code: .unsupportedFormatVersion,
                    message:
                        "Unsupported contract format version; this generator reads format version 1.",
                    path: ContractPath([.member("formatVersion")]),
                    location: member.value.location
                )
            ])
        }
    }

    private mutating func readProvenance(_ node: JSONNode) -> Provenance? {
        let path = ContractPath([.member("provenance")])
        guard
            let members = objectMembers(
                of: node,
                at: path,
                allowed: Set(Self.provenanceKeys),
                required: Self.provenanceKeys
            )
        else {
            return nil
        }
        let exporterVersion = members["exporterVersion"].flatMap {
            nonEmptyString($0, at: path.member("exporterVersion"))
        }
        let convexVersion = members["convexVersion"].flatMap {
            nonEmptyString($0, at: path.member("convexVersion"))
        }
        let typescriptVersion = members["typescriptVersion"].flatMap {
            nonEmptyString($0, at: path.member("typescriptVersion"))
        }
        var sourceHash: String?
        if let node = members["sourceHash"],
            let hash = nonEmptyString(node, at: path.member("sourceHash"))
        {
            if hash.utf8.count == 64, hash.utf8.allSatisfy(\.isHexDigit) {
                sourceHash = hash
            } else {
                report(
                    .invalidValue,
                    "Expected a SHA-256 hexadecimal digest.",
                    path.member("sourceHash"),
                    node.location
                )
            }
        }
        guard let exporterVersion, let convexVersion, let typescriptVersion, let sourceHash else {
            return nil
        }
        return Provenance(
            exporterVersion: exporterVersion,
            convexVersion: convexVersion,
            typescriptVersion: typescriptVersion,
            sourceHash: sourceHash
        )
    }

    private mutating func readTypes(_ node: JSONNode) -> [String: Shape] {
        guard case .object(let members) = node.value else {
            report(
                .invalidValue,
                "Expected `types` to be an object, found \(node.value.kindDescription).",
                ContractPath([.member("types")]),
                node.location
            )
            return [:]
        }
        var types: [String: Shape] = [:]
        var seen: Set<String> = []
        for member in members {
            let path = ContractPath.type(member.key)
            guard seen.insert(member.key).inserted else {
                report(
                    .duplicateType,
                    "The named type is defined more than once.",
                    path,
                    member.keyLocation
                )
                continue
            }
            if member.key.isEmpty {
                report(
                    .invalidValue,
                    "Named type names must not be empty.",
                    path,
                    member.keyLocation
                )
            }
            if let shape = readShape(member.value, at: path) {
                types[member.key] = shape
            }
        }
        return types
    }

    private mutating func readTables(_ node: JSONNode) -> [LocatedTable] {
        guard case .array(let elements) = node.value else {
            report(
                .invalidValue,
                "Expected `tables` to be an array, found \(node.value.kindDescription).",
                ContractPath([.member("tables")]),
                node.location
            )
            return []
        }
        var tables: [LocatedTable] = []
        for (index, element) in elements.enumerated() {
            let name = stringMember("name", of: element)
            let path =
                name.map(ContractPath.table) ?? ContractPath([.member("tables"), .index(index)])
            locations[path] = element.location
            guard
                let members = objectMembers(
                    of: element,
                    at: path,
                    allowed: ["name", "document"],
                    required: ["document", "name"]
                )
            else {
                continue
            }
            let validName = members["name"].flatMap { nonEmptyString($0, at: path.member("name")) }
            let document = members["document"].flatMap {
                readShape($0, at: path.member("document"))
            }
            if let validName, let document {
                tables.append(
                    LocatedTable(
                        table: ContractTable(name: validName, document: document),
                        location: element.location
                    )
                )
            }
        }
        return tables
    }

    private mutating func readFunctions(_ node: JSONNode) -> [LocatedFunction] {
        guard case .array(let elements) = node.value else {
            report(
                .invalidValue,
                "Expected `functions` to be an array, found \(node.value.kindDescription).",
                ContractPath([.member("functions")]),
                node.location
            )
            return []
        }
        var functions: [LocatedFunction] = []
        for (index, element) in elements.enumerated() {
            if let function = readFunction(element, index: index) {
                functions.append(function)
            }
        }
        return functions
    }

    private mutating func readFunction(_ node: JSONNode, index: Int) -> LocatedFunction? {
        let address = stringMember("path", of: node)
        let path =
            address.map(ContractPath.function)
            ?? ContractPath([.member("functions"), .index(index)])
        locations[path] = node.location
        source = nil
        defer { source = nil }
        guard
            let members = objectMembers(
                of: node,
                at: path,
                allowed: Self.functionKeys,
                required: Self.functionRequiredKeys
            )
        else {
            return nil
        }
        var sourceIsValid = true
        if let sourceNode = members["source"] {
            source = readSource(sourceNode, at: path.member("source"))
            sourceIsValid = source != nil
        }
        let functionPath = members["path"].flatMap { nonEmptyString($0, at: path.member("path")) }
        let module = members["module"].flatMap { readModule($0, at: path.member("module")) }
        let name = members["name"].flatMap { nonEmptyString($0, at: path.member("name")) }
        let kind = members["kind"].flatMap {
            enumeration(FunctionKind.self, $0, at: path.member("kind"))
        }
        let typeSource = members["typeSource"].flatMap {
            enumeration(TypeSource.self, $0, at: path.member("typeSource"))
        }
        var arguments: ObjectShape?
        if let node = members["arguments"],
            let shape = readShape(node, at: path.member("arguments"))
        {
            if case .object(let object) = shape {
                arguments = object
            } else {
                report(
                    .invalidValue,
                    "Function arguments must be an object shape.",
                    path.member("arguments"),
                    node.location
                )
            }
        }
        let result = members["result"].flatMap { readShape($0, at: path.member("result")) }
        guard
            sourceIsValid, let functionPath, let module, let name, let kind, let typeSource,
            let arguments,
            let result
        else {
            return nil
        }
        let function = ContractFunction(
            path: functionPath,
            module: module,
            name: name,
            kind: kind,
            arguments: arguments,
            result: result,
            typeSource: typeSource,
            source: source
        )
        return LocatedFunction(function: function, location: node.location)
    }

    private mutating func readModule(_ node: JSONNode, at path: ContractPath) -> [String]? {
        guard case .array(let elements) = node.value else {
            report(.invalidValue, "Expected an array of module path segments.", path, node.location)
            return nil
        }
        var segments: [String] = []
        for (index, element) in elements.enumerated() {
            guard let segment = nonEmptyString(element, at: path.index(index)) else {
                return nil
            }
            segments.append(segment)
        }
        return segments
    }

    private mutating func readSource(_ node: JSONNode, at path: ContractPath) -> SourceLocation? {
        guard
            let members = objectMembers(
                of: node,
                at: path,
                allowed: ["file", "line"],
                required: ["file", "line"]
            )
        else {
            return nil
        }
        var file: String?
        if let node = members["file"], let value = nonEmptyString(node, at: path.member("file")) {
            if value.hasPrefix("/") || value.contains("\\") {
                report(
                    .invalidValue,
                    "Source files must be repository-relative paths.",
                    path.member("file"),
                    node.location
                )
            } else {
                file = value
            }
        }
        var line: Int?
        if let node = members["line"] {
            if case .number(let lexeme) = node.value, let value = Int(lexeme), value >= 1 {
                line = value
            } else {
                report(
                    .invalidValue,
                    "Expected a one-based line number.",
                    path.member("line"),
                    node.location
                )
            }
        }
        guard let file, let line else {
            return nil
        }
        return SourceLocation(file: file, line: line)
    }

    // MARK: Shapes

    private mutating func readShape(_ node: JSONNode, at path: ContractPath) -> Shape? {
        locations[path] = node.location
        guard case .object(let rawMembers) = node.value else {
            report(
                .invalidValue,
                "Expected a shape object, found \(node.value.kindDescription).",
                path,
                node.location
            )
            return nil
        }
        guard let kindMember = rawMembers.first(where: { $0.key == "kind" }) else {
            report(.missingKey, "The shape has no `kind`.", path, node.location)
            return nil
        }
        guard case .string(let kind) = kindMember.value.value else {
            report(
                .invalidValue,
                "Expected `kind` to be a string.",
                path,
                kindMember.value.location
            )
            return nil
        }
        switch kind {
        case "string", "boolean", "float64", "bytes", "null", "dynamic":
            guard objectMembers(of: node, at: path, allowed: ["kind"], required: []) != nil else {
                return nil
            }
            switch kind {
            case "string": return .string
            case "boolean": return .boolean
            case "float64": return .float64
            case "bytes": return .bytes
            case "null": return .null
            default: return .dynamic
            }
        case "int64":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "semantic"],
                    required: []
                )
            else {
                return nil
            }
            guard let semanticNode = members["semantic"] else {
                return .int64(semantic: nil)
            }
            guard
                let semantic = enumeration(
                    Int64Semantic.self,
                    semanticNode,
                    at: path.member("semantic")
                )
            else {
                return nil
            }
            return .int64(semantic: semantic)
        case "id":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "table"],
                    required: ["table"]
                ),
                let table = members["table"].flatMap({
                    nonEmptyString($0, at: path.member("table"))
                })
            else {
                return nil
            }
            return .id(table: table)
        case "array":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "element"],
                    required: ["element"]
                ),
                let element = members["element"].flatMap({
                    readShape($0, at: path.member("element"))
                })
            else {
                return nil
            }
            return .array(element: element)
        case "object":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "fields"],
                    required: ["fields"]
                ),
                let fields = members["fields"].flatMap({ readFields($0, at: path) })
            else {
                return nil
            }
            return .object(ObjectShape(fields: fields))
        case "record":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "key", "value"],
                    required: ["key", "value"]
                )
            else {
                return nil
            }
            let key = members["key"].flatMap { readShape($0, at: path.member("key")) }
            let value = members["value"].flatMap { readShape($0, at: path.member("value")) }
            guard let key, let value else {
                return nil
            }
            return .record(key: key, value: value)
        case "union":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "variants"],
                    required: ["variants"]
                ),
                let variants = members["variants"].flatMap({
                    readShapeList($0, at: path.member("variants"))
                })
            else {
                return nil
            }
            guard !variants.isEmpty else {
                report(.emptyUnion, "A union needs at least one variant.", path, node.location)
                return nil
            }
            return .union(variants: variants)
        case "literal":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "value"],
                    required: ["value"]
                ),
                let value = members["value"].flatMap({ readLiteral($0, at: path) })
            else {
                return nil
            }
            return .literal(value)
        case "tuple":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "elements"],
                    required: ["elements"]
                ),
                let elements = members["elements"].flatMap({
                    readShapeList($0, at: path.member("elements"))
                })
            else {
                return nil
            }
            return .tuple(elements: elements)
        case "ref":
            guard
                let members = objectMembers(
                    of: node,
                    at: path,
                    allowed: ["kind", "name"],
                    required: ["name"]
                ),
                let name = members["name"].flatMap({ nonEmptyString($0, at: path.member("name")) })
            else {
                return nil
            }
            return .ref(name: name)
        default:
            report(
                .unknownShapeKind,
                "Unknown shape kind `\(kind)`.",
                path,
                kindMember.value.location
            )
            return nil
        }
    }

    private mutating func readShapeList(_ node: JSONNode, at path: ContractPath) -> [Shape]? {
        guard case .array(let elements) = node.value else {
            report(.invalidValue, "Expected an array of shapes.", path, node.location)
            return nil
        }
        var shapes: [Shape] = []
        var complete = true
        for (index, element) in elements.enumerated() {
            if let shape = readShape(element, at: path.index(index)) {
                shapes.append(shape)
            } else {
                complete = false
            }
        }
        return complete ? shapes : nil
    }

    private mutating func readFields(_ node: JSONNode, at objectPath: ContractPath) -> [Field]? {
        guard case .array(let elements) = node.value else {
            report(.invalidValue, "Expected `fields` to be an array.", objectPath, node.location)
            return nil
        }
        var fields: [Field] = []
        var seen: Set<String> = []
        var complete = true
        for (index, element) in elements.enumerated() {
            let name = stringMember("name", of: element)
            let path = name.map { objectPath.key($0) } ?? objectPath.member("fields").index(index)
            guard
                let members = objectMembers(
                    of: element,
                    at: path,
                    allowed: ["name", "type", "optional"],
                    required: ["name", "optional", "type"]
                )
            else {
                complete = false
                continue
            }
            var optional: Bool?
            if let node = members["optional"] {
                if case .bool(let value) = node.value {
                    optional = value
                } else {
                    report(
                        .invalidValue,
                        "Expected `optional` to be a boolean.",
                        path,
                        node.location
                    )
                }
            }
            let type = members["type"].flatMap { readShape($0, at: path) }
            locations[path] = element.location
            guard let name, let type, let optional else {
                if name == nil {
                    report(
                        .invalidValue,
                        "Expected the field `name` to be a string.",
                        path,
                        element.location
                    )
                }
                complete = false
                continue
            }
            guard seen.insert(name).inserted else {
                report(
                    .duplicateField,
                    "The object defines the field more than once.",
                    path,
                    element.location
                )
                complete = false
                continue
            }
            fields.append(Field(name: name, type: type, optional: optional))
        }
        return complete ? fields.sorted { $0.name < $1.name } : nil
    }

    private mutating func readLiteral(_ node: JSONNode, at path: ContractPath) -> LiteralValue? {
        switch node.value {
        case .string(let value):
            return .string(value)
        case .bool(let value):
            return .boolean(value)
        case .number(let lexeme):
            guard let value = Double(lexeme), value.isFinite else {
                report(
                    .invalidLiteral,
                    "Number literals must be finite Float64 values.",
                    path,
                    node.location
                )
                return nil
            }
            return .float64(value)
        case .object(let members):
            guard
                members.count == 1, members[0].key == "$integer",
                case .string(let encoded) = members[0].value.value,
                let data = Data(base64Encoded: encoded), data.count == 8,
                data.base64EncodedString() == encoded
            else {
                report(
                    .invalidLiteral,
                    #"Int64 literals must be a canonical {"$integer": "<base64 of 8 little-endian bytes>"} envelope."#,
                    path,
                    node.location
                )
                return nil
            }
            var bits: UInt64 = 0
            for (offset, byte) in data.enumerated() {
                bits |= UInt64(byte) << (8 * UInt64(offset))
            }
            return .int64(Int64(bitPattern: bits))
        case .null, .array:
            report(
                .invalidLiteral,
                "Literals must be a string, boolean, finite number, or Int64 envelope.",
                path,
                node.location
            )
            return nil
        }
    }

    // MARK: Semantic validation

    private mutating func validateSemantics(
        functions: [LocatedFunction],
        tables: [LocatedTable],
        types: [String: Shape]
    ) {
        var functionPaths: Set<String> = []
        for function in functions where !functionPaths.insert(function.function.path).inserted {
            report(
                .duplicateFunction,
                "More than one function has this Convex address.",
                .function(function.function.path),
                function.location
            )
        }
        var tableNames: Set<String> = []
        for table in tables where !tableNames.insert(table.table.name).inserted {
            report(
                .duplicateTable,
                "More than one table has this name.",
                .table(table.table.name),
                table.location
            )
        }
        let validTables = tableNames.union(["_storage"])

        var references: [String: Set<String>] = [:]
        for name in types.keys.sorted() {
            guard let shape = types[name] else { continue }
            var referenced: Set<String> = []
            checkShape(
                shape,
                at: .type(name),
                types: types,
                tables: validTables,
                references: &referenced
            )
            references[name] = referenced
        }
        for table in tables {
            var ignored: Set<String> = []
            checkShape(
                table.table.document,
                at: ContractPath.table(table.table.name).member("document"),
                types: types,
                tables: validTables,
                references: &ignored
            )
            for issue in DocumentShapeValidation.issues(for: table.table, types: types) {
                report(
                    .invalidValue,
                    issue.message,
                    issue.path,
                    locations[issue.path] ?? table.location
                )
            }
        }
        for function in functions {
            source = function.function.source
            var ignored: Set<String> = []
            let path = ContractPath.function(function.function.path)
            checkShape(
                .object(function.function.arguments),
                at: path.member("arguments"),
                types: types,
                tables: validTables,
                references: &ignored
            )
            checkShape(
                function.function.result,
                at: path.member("result"),
                types: types,
                tables: validTables,
                references: &ignored
            )
        }
        source = nil
        reportCycles(in: references)
    }

    private mutating func checkShape(
        _ shape: Shape,
        at path: ContractPath,
        types: [String: Shape],
        tables: Set<String>,
        references: inout Set<String>
    ) {
        switch shape {
        case .string, .boolean, .float64, .int64, .bytes, .null, .dynamic, .literal:
            break
        case .id(let table):
            if !tables.contains(table) {
                report(
                    .unknownTable,
                    "The ID refers to undefined table `\(table)`.",
                    path,
                    locations[path]
                )
            }
        case .array(let element):
            checkShape(
                element,
                at: path.member("element"),
                types: types,
                tables: tables,
                references: &references
            )
        case .object(let object):
            for field in object.fields {
                checkShape(
                    field.type,
                    at: path.key(field.name),
                    types: types,
                    tables: tables,
                    references: &references
                )
            }
        case .record(let key, let value):
            checkShape(
                key,
                at: path.member("key"),
                types: types,
                tables: tables,
                references: &references
            )
            checkShape(
                value,
                at: path.member("value"),
                types: types,
                tables: tables,
                references: &references
            )
            var visited: Set<String> = []
            if !isValidRecordKey(key, types: types, visited: &visited) {
                report(
                    .invalidRecordKey,
                    "Record keys must be a string, ID, string literal, or a union of those.",
                    path.member("key"),
                    locations[path.member("key")]
                )
            }
        case .union(let variants):
            for (index, variant) in variants.enumerated() {
                checkShape(
                    variant,
                    at: path.member("variants").index(index),
                    types: types,
                    tables: tables,
                    references: &references
                )
            }
        case .tuple(let elements):
            for (index, element) in elements.enumerated() {
                checkShape(
                    element,
                    at: path.member("elements").index(index),
                    types: types,
                    tables: tables,
                    references: &references
                )
            }
        case .ref(let name):
            references.insert(name)
            if types[name] == nil {
                report(
                    .danglingReference,
                    "The reference names undefined type `\(name)`.",
                    path,
                    locations[path]
                )
            }
        }
    }

    private func isValidRecordKey(
        _ shape: Shape,
        types: [String: Shape],
        visited: inout Set<String>
    ) -> Bool {
        switch shape {
        case .string, .id, .literal(.string):
            return true
        case .union(let variants):
            return variants.allSatisfy { isValidRecordKey($0, types: types, visited: &visited) }
        case .ref(let name):
            // Unresolved and recursive references have their own diagnostics.
            guard visited.insert(name).inserted, let target = types[name] else {
                return true
            }
            return isValidRecordKey(target, types: types, visited: &visited)
        default:
            return false
        }
    }

    /// Reports each strongly connected component of the named-type reference graph once.
    private mutating func reportCycles(in references: [String: Set<String>]) {
        var index = 0
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var onStack: Set<String> = []
        var components: [[String]] = []

        func connect(_ name: String) {
            indices[name] = index
            lowLinks[name] = index
            index += 1
            stack.append(name)
            onStack.insert(name)
            for target in (references[name] ?? []).sorted() where references[target] != nil {
                if indices[target] == nil {
                    connect(target)
                    lowLinks[name] = min(lowLinks[name] ?? 0, lowLinks[target] ?? 0)
                } else if onStack.contains(target) {
                    lowLinks[name] = min(lowLinks[name] ?? 0, indices[target] ?? 0)
                }
            }
            guard lowLinks[name] == indices[name] else {
                return
            }
            var component: [String] = []
            while let member = stack.popLast() {
                onStack.remove(member)
                component.append(member)
                if member == name {
                    break
                }
            }
            components.append(component.sorted())
        }

        for name in references.keys.sorted() where indices[name] == nil {
            connect(name)
        }
        for component in components {
            guard let first = component.first else { continue }
            let isCycle = component.count > 1 || references[first]?.contains(first) == true
            guard isCycle else { continue }
            let cycle = component.map { "`\($0)`" }.joined(separator: ", ")
            report(
                .recursiveReference,
                "Recursive shapes are unsupported; these named types refer to each other: \(cycle).",
                .type(first),
                locations[.type(first)]
            )
        }
    }

    // MARK: JSON helpers

    /// Returns an object's members, reporting duplicates, unexpected members, and missing members.
    private mutating func objectMembers(
        of node: JSONNode,
        at path: ContractPath,
        allowed: Set<String>,
        required: [String]
    ) -> [String: JSONNode]? {
        guard case .object(let members) = node.value else {
            report(
                .invalidValue,
                "Expected an object, found \(node.value.kindDescription).",
                path,
                node.location
            )
            return nil
        }
        var result: [String: JSONNode] = [:]
        var valid = true
        for member in members {
            guard allowed.contains(member.key) else {
                report(
                    .unexpectedKey,
                    "Unexpected member `\(member.key)`.",
                    path,
                    member.keyLocation
                )
                valid = false
                continue
            }
            guard result[member.key] == nil else {
                report(
                    .duplicateKey,
                    "The member `\(member.key)` appears more than once.",
                    path,
                    member.keyLocation
                )
                valid = false
                continue
            }
            result[member.key] = member.value
        }
        for key in required where result[key] == nil {
            report(.missingKey, "Missing required member `\(key)`.", path, node.location)
            valid = false
        }
        return valid ? result : nil
    }

    private func stringMember(_ key: String, of node: JSONNode) -> String? {
        guard
            case .object(let members) = node.value,
            let member = members.first(where: { $0.key == key }),
            case .string(let value) = member.value.value
        else {
            return nil
        }
        return value
    }

    private mutating func nonEmptyString(_ node: JSONNode, at path: ContractPath) -> String? {
        guard case .string(let value) = node.value, !value.isEmpty else {
            report(.invalidValue, "Expected a nonempty string.", path, node.location)
            return nil
        }
        return value
    }

    private mutating func enumeration<Value: RawRepresentable & CaseIterable>(
        _ type: Value.Type,
        _ node: JSONNode,
        at path: ContractPath
    ) -> Value? where Value.RawValue == String {
        guard case .string(let raw) = node.value, let value = Value(rawValue: raw) else {
            let allowed = Value.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
            report(.invalidValue, "Expected one of \(allowed).", path, node.location)
            return nil
        }
        return value
    }

    private mutating func report(
        _ code: ContractDiagnostic.Code,
        _ message: String,
        _ path: ContractPath,
        _ location: TextLocation?
    ) {
        diagnostics.append(
            ContractDiagnostic(
                code: code,
                message: message,
                path: path,
                location: location,
                source: source
            )
        )
    }
}

private struct LocatedFunction {
    var function: ContractFunction
    var location: TextLocation
}

private struct LocatedTable {
    var table: ContractTable
    var location: TextLocation
}

extension UInt8 {
    fileprivate var isHexDigit: Bool {
        (0x30...0x39).contains(self) || (0x41...0x46).contains(self) || (0x61...0x66).contains(self)
    }
}
