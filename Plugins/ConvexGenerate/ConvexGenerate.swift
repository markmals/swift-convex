import Foundation
import PackagePlugin

/// Generates `Convex.generated.swift` from the target's `convex-swift.json` during each build.
///
/// The output lives in the plugin work directory and is never written to package sources. A
/// configuration with `output` belongs to checked-in generation through `generate-convex`, so this
/// plugin rejects it instead of compiling the declarations twice.
@main
struct ConvexGenerate: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) async throws -> [Command] {
        guard target is any SourceModuleTarget else {
            throw PluginFailure(
                "ConvexGenerate applies only to source targets, not `\(target.name)`."
            )
        }
        let configuration = target.directoryURL.appendingPathComponent(
            GenerationCommand.configurationName
        )
        guard FileManager.default.fileExists(atPath: configuration.path) else {
            throw PluginFailure(
                "ConvexGenerate needs `\(GenerationCommand.configurationName)` in the directory of target "
                    + "`\(target.name)` (\(target.directoryURL.path))."
            )
        }
        return [
            try GenerationCommand.make(
                targetName: target.name,
                configuration: configuration,
                workDirectory: context.pluginWorkDirectoryURL,
                tool: context.tool(named: GenerationCommand.toolName).url
            )
        ]
    }
}

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    extension ConvexGenerate: XcodeBuildToolPlugin {
        func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws
            -> [Command]
        {
            let configurations = target.inputFiles.map(\.url).filter {
                $0.lastPathComponent == GenerationCommand.configurationName
            }
            guard configurations.count == 1, let configuration = configurations.first else {
                throw PluginFailure(
                    "ConvexGenerate needs exactly one `\(GenerationCommand.configurationName)` among the files "
                        + "of target `\(target.displayName)`; found \(configurations.count)."
                )
            }
            return [
                try GenerationCommand.make(
                    targetName: target.displayName,
                    configuration: configuration,
                    workDirectory: context.pluginWorkDirectoryURL,
                    tool: context.tool(named: GenerationCommand.toolName).url
                )
            ]
        }
    }
#endif

/// Builds the one generation command shared by the SwiftPM and Xcode hosts.
enum GenerationCommand {
    static let configurationName = "convex-swift.json"
    static let toolName = "convex-swift-codegen"
    static let outputName = "Convex.generated.swift"

    /// The members this plugin needs before the generator validates the whole configuration.
    private struct Summary: Decodable {
        var contract: String?
        var output: String?
    }

    static func make(targetName: String, configuration: URL, workDirectory: URL, tool: URL) throws
        -> Command
    {
        let output = workDirectory.appendingPathComponent(outputName)
        var inputs = [configuration]
        // An unreadable or malformed configuration still runs the generator, which reports the
        // problem with its exact location and fails the build.
        if let data = try? Data(contentsOf: configuration),
            let summary = try? JSONDecoder().decode(Summary.self, from: data)
        {
            guard summary.output == nil else {
                throw PluginFailure(
                    "\(configuration.path) sets `output` for checked-in generation with "
                        + "`swift package generate-convex`; remove `output` or remove the ConvexGenerate plugin "
                        + "from `\(targetName)` so the declarations are not compiled twice."
                )
            }
            if let contract = summary.contract, !contract.isEmpty, !contract.hasPrefix("/") {
                inputs.append(
                    configuration.deletingLastPathComponent().appendingPathComponent(contract)
                        .standardizedFileURL
                )
            }
        }
        return .buildCommand(
            displayName: "Generating Convex Swift API for \(targetName)",
            executable: tool,
            arguments: ["--config", configuration.path, "--output", output.path],
            inputFiles: inputs,
            outputFiles: [output]
        )
    }
}

struct PluginFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
