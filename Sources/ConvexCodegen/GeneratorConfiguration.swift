public import ConvexContract
public import Foundation

extension ContractDiagnostic.Code {
    /// The Swift generation configuration is malformed.
    public static let invalidConfiguration = Self(rawValue: "invalidConfiguration")
    /// An input file could not be read.
    public static let unreadableFile = Self(rawValue: "unreadableFile")
}

/// The target-local `convex-swift.json` settings for Swift generation.
///
/// The file is an object with `contract` (a path relative to the configuration file), optional
/// `namespace` (default `API`), optional `output` (a path relative to the configuration file, required
/// for checked-in generation), and optional `names`, which maps rendered contract paths such as
/// `functions[messages:list]` or `functions[messages:list].arguments[channelId]` to Swift
/// identifiers. Overrides change only Swift spelling, never routing or wire keys.
public struct GeneratorConfiguration: Sendable {
    /// The configuration file name that plugins look for in a target directory.
    public static let fileName = "convex-swift.json"

    /// The neutral contract to generate from.
    public var contractURL: URL
    /// The root namespace for generated declarations.
    public var namespace: String
    /// The checked-in output file, when the configuration names one.
    public var outputURL: URL?
    /// Swift spelling overrides keyed by rendered contract paths.
    public var names: [String: String]

    package var nameLocations: [String: TextLocation] = [:]

    /// Creates a configuration directly.
    public init(
        contractURL: URL,
        namespace: String = "API",
        outputURL: URL? = nil,
        names: [String: String] = [:]
    ) {
        self.contractURL = contractURL
        self.namespace = namespace
        self.outputURL = outputURL
        self.names = names
    }

    /// Reads and validates a configuration file.
    ///
    /// - Throws: ``ContractError`` whose diagnostics refer to the configuration file.
    public init(contentsOf url: URL) throws(ContractError) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ContractError(diagnostics: [
                ContractDiagnostic(
                    code: .unreadableFile,
                    message: "Cannot read the configuration: \(error.localizedDescription)",
                    file: .configuration
                )
            ])
        }
        let root: JSONNode
        do throws(JSONSyntaxError) {
            root = try JSONParser.parse(data)
        } catch {
            throw ContractError(diagnostics: [
                ContractDiagnostic(
                    code: .syntax,
                    message: error.message,
                    file: .configuration,
                    location: error.location
                )
            ])
        }
        var diagnostics: [ContractDiagnostic] = []
        func fail(_ message: String, _ location: TextLocation?) {
            diagnostics.append(
                ContractDiagnostic(
                    code: .invalidConfiguration,
                    message: message,
                    file: .configuration,
                    location: location
                )
            )
        }
        guard case .object(let members) = root.value else {
            throw ContractError(diagnostics: [
                ContractDiagnostic(
                    code: .invalidConfiguration,
                    message: "Expected the configuration to be an object.",
                    file: .configuration,
                    location: root.location
                )
            ])
        }
        let directory = url.deletingLastPathComponent()
        var seen: Set<String> = []
        var contract: URL?
        var namespace = "API"
        var output: URL?
        var names: [String: String] = [:]
        var nameLocations: [String: TextLocation] = [:]

        func relativePath(_ node: JSONNode, member: String) -> URL? {
            guard case .string(let path) = node.value, !path.isEmpty else {
                fail("Expected `\(member)` to be a nonempty path.", node.location)
                return nil
            }
            guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
                fail("`\(member)` must be relative to the configuration file.", node.location)
                return nil
            }
            return directory.appending(path: path).standardizedFileURL
        }

        for member in members {
            guard seen.insert(member.key).inserted else {
                fail("The member `\(member.key)` appears more than once.", member.keyLocation)
                continue
            }
            switch member.key {
            case "contract":
                contract = relativePath(member.value, member: "contract")
            case "output":
                output = relativePath(member.value, member: "output")
            case "namespace":
                if case .string(let value) = member.value.value {
                    namespace = value
                } else {
                    fail("Expected `namespace` to be a string.", member.value.location)
                }
            case "names":
                guard case .object(let entries) = member.value.value else {
                    fail(
                        "Expected `names` to map contract paths to Swift identifiers.",
                        member.value.location
                    )
                    continue
                }
                for entry in entries {
                    guard names[entry.key] == nil else {
                        fail(
                            "The `names` key `\(entry.key)` appears more than once.",
                            entry.keyLocation
                        )
                        continue
                    }
                    guard case .string(let value) = entry.value.value else {
                        fail(
                            "Expected the `names` override for `\(entry.key)` to be a string.",
                            entry.value.location
                        )
                        continue
                    }
                    names[entry.key] = value
                    nameLocations[entry.key] = entry.keyLocation
                }
            default:
                fail("Unexpected member `\(member.key)`.", member.keyLocation)
            }
        }
        if !seen.contains("contract") {
            fail("Missing required member `contract`.", root.location)
        }
        guard diagnostics.isEmpty, let contract else {
            throw ContractError(diagnostics: diagnostics.sortedForReport())
        }
        self.init(contractURL: contract, namespace: namespace, outputURL: output, names: names)
        self.nameLocations = nameLocations
    }
}
