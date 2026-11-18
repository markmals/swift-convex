struct DocumentShapeValidation {
    struct Issue {
        let path: ContractPath
        let message: String
    }

    static func issues(for table: ContractTable, types: [String: Shape]) -> [Issue] {
        var issues: [Issue] = []
        var visiting: Set<String> = []
        check(
            table.document,
            table: table.name,
            path: .table(table.name).member("document"),
            types: types,
            visiting: &visiting,
            issues: &issues
        )
        return issues
    }

    private static func check(
        _ shape: Shape,
        table: String,
        path: ContractPath,
        types: [String: Shape],
        visiting: inout Set<String>,
        issues: inout [Issue]
    ) {
        switch shape {
        case .dynamic:
            return
        case .ref(let name):
            guard let referenced = types[name], visiting.insert(name).inserted else { return }
            defer { visiting.remove(name) }
            check(
                referenced,
                table: table,
                path: path,
                types: types,
                visiting: &visiting,
                issues: &issues
            )
        case .union(let variants):
            for (index, variant) in variants.enumerated() {
                check(
                    variant,
                    table: table,
                    path: path.member("variants").index(index),
                    types: types,
                    visiting: &visiting,
                    issues: &issues
                )
            }
        case .object(let object):
            checkField(
                "_id",
                expected: .id(table: table),
                in: object,
                path: path,
                types: types,
                issues: &issues
            )
            checkField(
                "_creationTime",
                expected: .float64,
                in: object,
                path: path,
                types: types,
                issues: &issues
            )
        default:
            issues.append(
                Issue(
                    path: path,
                    message: "A table document must be an object with required system fields."
                )
            )
        }
    }

    private static func checkField(
        _ name: String,
        expected: Shape,
        in object: ObjectShape,
        path: ContractPath,
        types: [String: Shape],
        issues: inout [Issue]
    ) {
        let fieldPath = path.key(name)
        guard let field = object.fields.first(where: { $0.name == name }), !field.optional else {
            issues.append(
                Issue(
                    path: fieldPath,
                    message: "A table document requires a non-optional `\(name)` field."
                )
            )
            return
        }
        var shape = field.type
        var visiting: Set<String> = []
        while case .ref(let name) = shape {
            guard let referenced = types[name], visiting.insert(name).inserted else { return }
            shape = referenced
        }
        guard shape == expected || shape == .dynamic else {
            let requirement = name == "_id" ? "an ID for its own table" : "Float64 milliseconds"
            issues.append(
                Issue(
                    path: fieldPath,
                    message: "The `\(name)` system field must be \(requirement)."
                )
            )
            return
        }
    }
}
