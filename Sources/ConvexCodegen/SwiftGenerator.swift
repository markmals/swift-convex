public import ConvexContract

/// Generates one Swift source file of requests, tables, and types from a validated contract.
///
/// Output is deterministic: it depends only on the contract and the generator settings, never on
/// input ordering, time, or the machine. Generation fails, rather than approximating, when a union
/// cannot be decoded without guessing or when Swift names collide.
public struct SwiftGenerator: Sendable {
    /// The root namespace for generated declarations.
    public var namespace: String
    /// Swift spelling overrides keyed by rendered contract paths.
    public var names: [String: String]

    private var nameLocations: [String: TextLocation]

    /// Creates a generator with a namespace and optional name overrides.
    public init(namespace: String = "API", names: [String: String] = [:]) {
        self.namespace = namespace
        self.names = names
        self.nameLocations = [:]
    }

    /// Creates a generator from a configuration file's settings.
    public init(configuration: GeneratorConfiguration) {
        self.namespace = configuration.namespace
        self.names = configuration.names
        self.nameLocations = configuration.nameLocations
    }

    /// Returns the Swift source for a contract.
    ///
    /// - Throws: ``ContractError`` describing every overlapping union, name collision, and invalid
    ///   or unused name override.
    public func generate(from contract: ContractDocument) throws(ContractError) -> String {
        SwiftRenderer.render(try lower(contract))
    }

    func lower(_ contract: ContractDocument) throws(ContractError) -> GeneratedModule {
        var lowerer = Lowerer(
            contract: contract,
            namespace: namespace,
            overrides: NameOverrides(names, locations: nameLocations)
        )
        switch lowerer.lower() {
        case .success(let module):
            return module
        case .failure(let error):
            throw error
        }
    }
}
