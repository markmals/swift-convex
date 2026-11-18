import ConvexCodegen
import Foundation

/// The `convex-swift-codegen` command.
///
/// ```
/// convex-swift-codegen --config <convex-swift.json> [--output <file>] [--check]
/// ```
///
/// Reads only the local configuration and contract. `--output` overrides the configuration's
/// `output`; `--check` compares without writing and exits unsuccessfully on drift.
@main
enum ConvexSwiftCodegen {
    private struct Invocation {
        var configuration: URL
        var output: URL?
        var check: Bool
    }

    private struct UsageError: Error {
        var message: String
    }

    private static let usage =
        "usage: convex-swift-codegen --config <path> [--output <path>] [--check]"

    static func main() {
        let invocation: Invocation
        do throws(UsageError) {
            guard let parsed = try parse(CommandLine.arguments.dropFirst()) else {
                print(usage)
                return
            }
            invocation = parsed
        } catch {
            writeError("error: \(error.message)\n\(usage)")
            exit(64)
        }
        do throws(CodegenError) {
            let outcome = try Codegen.run(
                configurationURL: invocation.configuration,
                outputURL: invocation.output,
                mode: invocation.check ? .check : .write
            )
            if case .updated(let output) = outcome {
                print("Updated \(output.path(percentEncoded: false))")
            }
        } catch {
            writeError(error.description)
            exit(1)
        }
    }

    /// Returns `nil` when help was requested.
    private static func parse(_ arguments: ArraySlice<String>) throws(UsageError) -> Invocation? {
        var configuration: URL?
        var output: URL?
        var check = false
        var index = arguments.startIndex
        func value(for option: String) throws(UsageError) -> URL {
            index += 1
            guard index < arguments.endIndex, !arguments[index].hasPrefix("--") else {
                throw UsageError(message: "\(option) requires a path.")
            }
            return URL(filePath: arguments[index]).absoluteURL.standardizedFileURL
        }
        while index < arguments.endIndex {
            switch arguments[index] {
            case "--config":
                guard configuration == nil else {
                    throw UsageError(message: "--config was given more than once.")
                }
                configuration = try value(for: "--config")
            case "--output":
                guard output == nil else {
                    throw UsageError(message: "--output was given more than once.")
                }
                output = try value(for: "--output")
            case "--check":
                check = true
            case "--help", "-h":
                return nil
            default:
                throw UsageError(message: "Unexpected argument `\(arguments[index])`.")
            }
            index += 1
        }
        guard let configuration else {
            throw UsageError(message: "--config is required.")
        }
        return Invocation(configuration: configuration, output: output, check: check)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
