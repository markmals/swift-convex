public import ConvexContract
public import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Runs configuration-driven generation: read, validate, generate, then check or write one file.
public enum Codegen {
    /// What to do with the generated source.
    public enum Mode: Sendable {
        /// Replace the output atomically when its contents differ.
        case write
        /// Compare with the output without writing, failing on drift.
        case check
    }

    /// The effect of a successful run.
    public enum Outcome: Sendable, Equatable {
        /// The output file was created or replaced.
        case updated(URL)
        /// The output file already matched; nothing was written.
        case unchanged(URL)
    }

    /// Generates the output configured by a `convex-swift.json` file.
    ///
    /// Nothing is written unless every input is valid, and an existing output that already matches is
    /// left untouched so its modification date does not trigger rebuilds.
    ///
    /// - Parameters:
    ///   - configurationURL: The configuration file.
    ///   - outputURL: The output file. When `nil`, the configuration's `output` is used.
    ///   - mode: Whether to write or only check.
    /// - Returns: Whether the output was updated or already matched.
    /// - Throws: Invalid inputs, file-system failures, or drift in check mode.
    public static func run(
        configurationURL: URL,
        outputURL: URL? = nil,
        mode: Mode
    ) throws(CodegenError) -> Outcome {
        let configuration: GeneratorConfiguration
        do throws(ContractError) {
            configuration = try GeneratorConfiguration(contentsOf: configurationURL)
        } catch {
            throw CodegenError.invalidInput(
                diagnostics: error.diagnostics,
                configurationURL: configurationURL,
                contractURL: nil
            )
        }
        guard let output = outputURL ?? configuration.outputURL else {
            throw CodegenError.missingOutput(configurationURL: configurationURL)
        }
        let source: String
        do throws(ContractError) {
            let data: Data
            do {
                data = try Data(contentsOf: configuration.contractURL)
            } catch {
                throw ContractError(diagnostics: [
                    ContractDiagnostic(
                        code: .unreadableFile,
                        message: "Cannot read the contract: \(error.localizedDescription)"
                    )
                ])
            }
            let contract = try ContractDocument(data: data)
            source = try SwiftGenerator(configuration: configuration).generate(from: contract)
        } catch {
            throw CodegenError.invalidInput(
                diagnostics: error.diagnostics,
                configurationURL: configurationURL,
                contractURL: configuration.contractURL
            )
        }
        let existing = try GeneratedFile.contents(of: output)
        if existing == source {
            return .unchanged(output)
        }
        switch mode {
        case .check:
            throw CodegenError.outdated(outputURL: output)
        case .write:
            try GeneratedFile.replace(output, with: source)
            return .updated(output)
        }
    }
}

/// Why generation did not complete.
public enum CodegenError: Error, Sendable, CustomStringConvertible {
    /// The configuration or contract is invalid or unsupported.
    case invalidInput(diagnostics: [ContractDiagnostic], configurationURL: URL, contractURL: URL?)
    /// Neither the caller nor the configuration named an output file.
    case missingOutput(configurationURL: URL)
    /// Check mode found that the output does not match the contract.
    case outdated(outputURL: URL)
    /// Reading or writing a file failed.
    case fileSystem(url: URL, reason: String)

    /// Compiler-style `file:line:column: error:` lines.
    public var description: String {
        switch self {
        case .invalidInput(let diagnostics, let configurationURL, let contractURL):
            return diagnostics.map { diagnostic in
                let file =
                    diagnostic.file == .configuration
                    ? configurationURL : (contractURL ?? configurationURL)
                var prefix = file.path(percentEncoded: false)
                if let location = diagnostic.location {
                    prefix += ":\(location.line):\(location.column)"
                }
                return "\(prefix): error: \(diagnostic)"
            }
            .joined(separator: "\n")
        case .missingOutput(let configurationURL):
            return
                "\(configurationURL.path(percentEncoded: false)): error: Set `output` in the configuration "
                + "or pass --output; checked-in generation needs a destination file."
        case .outdated(let outputURL):
            return
                "\(outputURL.path(percentEncoded: false)): error: The generated Swift is out of date with "
                + "the Convex contract; run generation to update it."
        case .fileSystem(let url, let reason):
            return "\(url.path(percentEncoded: false)): error: \(reason)"
        }
    }
}

/// Reads and atomically replaces generated files.
enum GeneratedFile {
    /// The file's UTF-8 contents, or `nil` when it does not exist.
    static func contents(of url: URL) throws(CodegenError) -> String? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        do {
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        } catch {
            throw CodegenError.fileSystem(
                url: url,
                reason: "Cannot read the existing output: \(error.localizedDescription)"
            )
        }
    }

    /// Writes a sibling temporary file and renames it over the destination, so readers see either the
    /// old file or the complete new one.
    static func replace(_ url: URL, with contents: String) throws(CodegenError) {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: temporary, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CodegenError.fileSystem(
                url: url,
                reason: "Cannot write the output: \(error.localizedDescription)"
            )
        }
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else {
                    return Int32(-1)
                }
                return rename(source, destination)
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw CodegenError.fileSystem(url: url, reason: "Cannot replace the output: \(reason)")
        }
    }
}
