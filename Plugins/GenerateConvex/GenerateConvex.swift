import Foundation
import PackagePlugin

/// Writes checked-in Convex Swift sources, or verifies them with `--check`.
///
/// ```
/// swift package --allow-writing-to-package-directory generate-convex [--target <name>]... [--check]
/// ```
///
/// Each selected target's `convex-swift.json` must set `output`. Without `--target`, every target
/// that contains a configuration is generated.
@main
struct GenerateConvex: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let options = try Options(arguments)
        let targets =
            options.targetNames.isEmpty
            ? context.package.targets : try context.package.targets(named: options.targetNames)
        var configurations: [URL] = []
        for target in targets {
            let configuration = target.directoryURL.appendingPathComponent(
                Generation.configurationName
            )
            if FileManager.default.fileExists(atPath: configuration.path) {
                configurations.append(configuration)
            } else if !options.targetNames.isEmpty {
                throw PluginFailure(
                    "Target `\(target.name)` has no `\(Generation.configurationName)`."
                )
            }
        }
        try Generation.run(
            configurations: configurations,
            tool: context.tool(named: Generation.toolName).url,
            check: options.check
        )
    }
}

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    extension GenerateConvex: XcodeCommandPlugin {
        func performCommand(context: XcodePluginContext, arguments: [String]) throws {
            let options = try Options(arguments)
            var configurations: [URL] = []
            for target in context.xcodeProject.targets
            where options.targetNames.isEmpty || options.targetNames.contains(target.displayName) {
                let matches = target.inputFiles.map(\.url).filter {
                    $0.lastPathComponent == Generation.configurationName
                }
                if matches.count > 1 {
                    throw PluginFailure(
                        "Target `\(target.displayName)` has more than one `\(Generation.configurationName)`."
                    )
                }
                if let configuration = matches.first {
                    configurations.append(configuration)
                } else if !options.targetNames.isEmpty {
                    throw PluginFailure(
                        "Target `\(target.displayName)` has no `\(Generation.configurationName)`."
                    )
                }
            }
            try Generation.run(
                configurations: configurations,
                tool: context.tool(named: Generation.toolName).url,
                check: options.check
            )
        }
    }
#endif

/// The command's arguments.
struct Options {
    var targetNames: [String]
    var check: Bool

    init(_ arguments: [String]) throws {
        var extractor = ArgumentExtractor(arguments)
        targetNames = extractor.extractOption(named: "target")
        check = extractor.extractFlag(named: "check") > 0
        guard extractor.remainingArguments.isEmpty else {
            throw PluginFailure(
                "Unexpected arguments: \(extractor.remainingArguments.joined(separator: " ")). "
                    + "Usage: generate-convex [--target <name>]... [--check]"
            )
        }
    }
}

/// Runs the generator once per configuration and fails if any run fails.
enum Generation {
    static let configurationName = "convex-swift.json"
    static let toolName = "convex-swift-codegen"

    static func run(configurations: [URL], tool: URL, check: Bool) throws {
        guard !configurations.isEmpty else {
            throw PluginFailure("No target contains `\(configurationName)`.")
        }
        var failed: [String] = []
        for configuration in configurations {
            let process = Process()
            process.executableURL = tool
            process.arguments = ["--config", configuration.path] + (check ? ["--check"] : [])
            try process.run()
            process.waitUntilExit()
            if process.terminationReason != .exit || process.terminationStatus != 0 {
                failed.append(configuration.path)
            }
        }
        guard failed.isEmpty else {
            let action = check ? "Checking" : "Generating"
            throw PluginFailure(
                "\(action) Convex Swift sources failed for \(failed.joined(separator: ", "))."
            )
        }
    }
}

struct PluginFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
