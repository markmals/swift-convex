import ConvexCodegen
import ConvexContract
import Foundation
import Testing

@Suite("Generation runs")
struct CodegenRunTests {
    typealias J = ContractJSON

    /// A temporary directory holding a contract and a configuration, removed with the value.
    private final class Workspace {
        let directory: URL

        init(contract: String, configuration: String) throws {
            directory = FileManager.default.temporaryDirectory.appending(
                path: "convex-codegen-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(contract.utf8).write(to: directory.appending(path: "contract.json"))
            try Data(configuration.utf8).write(to: directory.appending(path: "convex-swift.json"))
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        var configurationURL: URL { directory.appending(path: "convex-swift.json") }

        func url(_ path: String) -> URL { directory.appending(path: path) }
    }

    private static let validContract = J.document(
        functions: [J.function("messages:list", arguments: [J.field("channelId", J.string)])]
    )

    private static let checkedInConfiguration =
        #"{"contract": "contract.json", "output": "Generated/API.swift"}"#

    @Test func checkReportsDriftWithoutWriting() throws {
        let workspace = try Workspace(
            contract: Self.validContract,
            configuration: Self.checkedInConfiguration
        )
        let output = workspace.url("Generated/API.swift").standardizedFileURL
        do throws(CodegenError) {
            _ = try Codegen.run(configurationURL: workspace.configurationURL, mode: .check)
            Issue.record("Check succeeded without an output file")
        } catch {
            guard case .outdated(let reported) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(reported == output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test func writingIsIdempotentAndCheckPassesAfterward() throws {
        let workspace = try Workspace(
            contract: Self.validContract,
            configuration: Self.checkedInConfiguration
        )
        let output = workspace.url("Generated/API.swift").standardizedFileURL
        #expect(
            try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
                == .updated(output)
        )
        let written = try Data(contentsOf: output)
        let modified = try FileManager.default.attributesOfItem(
            atPath: output.path(percentEncoded: false)
        )[
            .modificationDate
        ]

        #expect(
            try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
                == .unchanged(output)
        )
        #expect(
            try Codegen.run(configurationURL: workspace.configurationURL, mode: .check)
                == .unchanged(output)
        )
        #expect(try Data(contentsOf: output) == written)
        let unchanged = try FileManager.default.attributesOfItem(
            atPath: output.path(percentEncoded: false)
        )[
            .modificationDate
        ]
        #expect(modified as? Date == unchanged as? Date)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: output.deletingLastPathComponent().path(percentEncoded: false)
        )
        #expect(leftovers == ["API.swift"])
    }

    @Test func changedContractsReplaceTheWholeOutput() throws {
        let workspace = try Workspace(
            contract: Self.validContract,
            configuration: Self.checkedInConfiguration
        )
        let output = workspace.url("Generated/API.swift").standardizedFileURL
        _ = try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
        let before = try String(contentsOf: output, encoding: .utf8)

        let renamed = J.document(functions: [J.function("messages:recent")])
        try Data(renamed.utf8).write(to: workspace.url("contract.json"))
        #expect(throws: CodegenError.self) {
            try Codegen.run(configurationURL: workspace.configurationURL, mode: .check)
        }
        #expect(
            try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
                == .updated(output)
        )
        let after = try String(contentsOf: output, encoding: .utf8)
        #expect(after != before)
        let expected = try SwiftGenerator().generate(
            from: ContractDocument(data: Data(renamed.utf8))
        )
        #expect(after == expected)
    }

    @Test func invalidContractsLeaveTheExistingOutputUntouched() throws {
        let invalid = J.document(functions: [J.function("a:b", result: #"{"kind": "mystery"}"#)])
        let workspace = try Workspace(contract: invalid, configuration: Self.checkedInConfiguration)
        let output = workspace.url("Generated/API.swift")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("previous".utf8).write(to: output)
        do throws(CodegenError) {
            _ = try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
            Issue.record("Generation succeeded with an invalid contract")
        } catch {
            guard case .invalidInput(let diagnostics, _, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(diagnostics.map(\.code) == [.unknownShapeKind])
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "previous")
    }

    @Test func explicitOutputOverridesTheConfiguration() throws {
        let workspace = try Workspace(
            contract: Self.validContract,
            configuration: #"{"contract": "contract.json"}"#
        )
        do throws(CodegenError) {
            _ = try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
            Issue.record("Generation succeeded without an output")
        } catch {
            guard case .missingOutput = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        let output = workspace.url("Work/Convex.generated.swift")
        #expect(
            try Codegen.run(
                configurationURL: workspace.configurationURL,
                outputURL: output,
                mode: .write
            )
                == .updated(output)
        )
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test(arguments: [
        #"{"contract": "/absolute/contract.json"}"#,
        #"{"contract": "contract.json", "outputs": "API.swift"}"#,
        #"{"contract": "contract.json", "names": {"functions[a:b]": 1}}"#,
        #"{"contract": "contract.json", "contract": "other.json"}"#,
        #"{"namespace": "API"}"#,
    ])
    func malformedConfigurationsFail(configuration: String) throws {
        let workspace = try Workspace(contract: Self.validContract, configuration: configuration)
        do throws(CodegenError) {
            _ = try Codegen.run(
                configurationURL: workspace.configurationURL,
                outputURL: workspace.url("API.swift"),
                mode: .write
            )
            Issue.record("Generation accepted a malformed configuration")
        } catch {
            guard case .invalidInput(let diagnostics, _, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(!diagnostics.isEmpty)
            #expect(
                diagnostics.allSatisfy {
                    $0.file == .configuration && $0.code == .invalidConfiguration
                }
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: workspace.url("API.swift").path(percentEncoded: false)
            )
        )
    }

    @Test func contractDiagnosticsPointAtTheContractFile() throws {
        let invalid = J.document(functions: [J.function("a:b", result: J.ref("Missing"))])
        let workspace = try Workspace(contract: invalid, configuration: Self.checkedInConfiguration)
        do throws(CodegenError) {
            _ = try Codegen.run(configurationURL: workspace.configurationURL, mode: .write)
            Issue.record("Generation succeeded with a dangling reference")
        } catch {
            let contractPath = workspace.url("contract.json").standardizedFileURL.path(
                percentEncoded: false
            )
            let line = try #require(error.description.split(separator: "\n").first)
            #expect(line.hasPrefix(contractPath + ":"))
            #expect(line.contains(": error: functions[a:b].result: "))
        }
    }
}
