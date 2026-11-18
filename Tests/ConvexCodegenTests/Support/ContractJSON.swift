import ConvexContract
import Foundation

@testable import ConvexCodegen

/// Builds small contract documents for tests.
enum ContractJSON {
    static let string = #"{"kind":"string"}"#
    static let boolean = #"{"kind":"boolean"}"#
    static let float64 = #"{"kind":"float64"}"#
    static let int64 = #"{"kind":"int64"}"#
    static let bytes = #"{"kind":"bytes"}"#
    static let null = #"{"kind":"null"}"#
    static let dynamic = #"{"kind":"dynamic"}"#

    static func document(
        functions: [String] = [],
        tables: [String] = [],
        types: [(String, String)] = [],
        formatVersion: String = "1"
    ) -> String {
        let typeMembers = types.map { "\(quoted($0.0)): \($0.1)" }.joined(separator: ",\n")
        return """
            {
              "formatVersion": \(formatVersion),
              "provenance": {
                "exporterVersion": "test",
                "convexVersion": "1.50.0",
                "typescriptVersion": "5.9.3",
                "sourceHash": "\(String(repeating: "ab", count: 32))"
              },
              "functions": [\(functions.joined(separator: ",\n"))],
              "tables": [\(tables.joined(separator: ",\n"))],
              "types": {\(typeMembers)}
            }
            """
    }

    /// A function whose module path and name derive from its Convex address.
    static func function(
        _ path: String,
        kind: String = "query",
        arguments: [String] = [],
        result: String = null,
        source: String? = nil
    ) -> String {
        let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
        let module = parts[0].split(separator: "/").map { quoted(String($0)) }.joined(
            separator: ", "
        )
        let sourceMember = source.map { #", "source": \#($0)"# } ?? ""
        return """
            {"path": \(quoted(path)), "module": [\(module)], "name": \(quoted(parts[1])), "kind": \(quoted(kind)), \
            "arguments": \(object(arguments)), "result": \(result), "typeSource": "inferred"\(sourceMember)}
            """
    }

    static func table(_ name: String, document: String? = nil) -> String {
        let document =
            document
            ?? object([
                field("_id", id(name)), field("_creationTime", float64),
            ])
        return #"{"name": \#(quoted(name)), "document": \#(document)}"#
    }

    static func field(_ name: String, _ type: String, optional: Bool = false) -> String {
        #"{"name": \#(quoted(name)), "type": \#(type), "optional": \#(optional)}"#
    }

    static func object(_ fields: [String]) -> String {
        #"{"kind": "object", "fields": [\#(fields.joined(separator: ", "))]}"#
    }

    static func union(_ variants: String...) -> String {
        #"{"kind": "union", "variants": [\#(variants.joined(separator: ", "))]}"#
    }

    static func array(_ element: String) -> String {
        #"{"kind": "array", "element": \#(element)}"#
    }

    static func tuple(_ elements: String...) -> String {
        #"{"kind": "tuple", "elements": [\#(elements.joined(separator: ", "))]}"#
    }

    static func record(key: String, value: String) -> String {
        #"{"kind": "record", "key": \#(key), "value": \#(value)}"#
    }

    static func literal(_ value: String) -> String {
        #"{"kind": "literal", "value": \#(value)}"#
    }

    static func ref(_ name: String) -> String {
        #"{"kind": "ref", "name": \#(quoted(name))}"#
    }

    static func id(_ table: String) -> String {
        #"{"kind": "id", "table": \#(quoted(table))}"#
    }

    static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }
}

/// Reads a contract, returning its diagnostics instead of throwing.
func contractDiagnostics(_ json: String) -> [ContractDiagnostic] {
    do throws(ContractError) {
        _ = try ContractDocument(data: Data(json.utf8))
        return []
    } catch {
        return error.diagnostics
    }
}

/// Lowers a valid contract into the generated Swift declaration model.
func generatedModule(
    _ json: String,
    namespace: String = "API",
    names: [String: String] = [:]
) throws -> GeneratedModule {
    let contract = try ContractDocument(data: Data(json.utf8))
    return try SwiftGenerator(namespace: namespace, names: names).lower(contract)
}

/// Returns the diagnostics that stop Swift generation for a valid contract.
func generationDiagnostics(_ json: String, names: [String: String] = [:]) throws
    -> [ContractDiagnostic]
{
    let contract = try ContractDocument(data: Data(json.utf8))
    do throws(ContractError) {
        _ = try SwiftGenerator(names: names).lower(contract)
        return []
    } catch {
        return error.diagnostics
    }
}

extension GeneratedModule {
    /// The declaration with a dotted name, or a recorded test failure.
    func required(_ name: String) throws -> Declaration {
        guard let declaration = declaration(named: name) else {
            throw MissingDeclaration(name: name, available: declarations.map(\.name.description))
        }
        return declaration
    }
}

struct MissingDeclaration: Error, CustomStringConvertible {
    var name: String
    var available: [String]

    var description: String {
        "No declaration named \(name); generated: \(available.joined(separator: ", "))"
    }
}

extension Declaration {
    var properties: [Property] {
        switch kind {
        case .model(let properties): properties
        case .request(let request): request.properties
        default: []
        }
    }

    func property(_ name: String) -> Property? {
        properties.first { $0.name == name }
    }

    var union: Union? {
        guard case .union(let union) = kind else { return nil }
        return union
    }

    var aliasedType: SwiftType? {
        guard case .alias(let type) = kind else { return nil }
        return type
    }
}
