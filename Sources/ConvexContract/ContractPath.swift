/// The location of a declaration or shape inside a contract, independent of JSON layout.
///
/// Paths identify functions, tables, named types, and modules by their backend names rather than
/// array positions, so the same path stays valid when unrelated declarations change. They render as
/// `functions[messages:list].arguments[channelId]` and are also the keys of the Swift
/// configuration's `names` overrides.
public struct ContractPath: Hashable, Sendable, CustomStringConvertible {
    /// One step in a contract path.
    public enum Component: Hashable, Sendable {
        /// A fixed member such as `result`, `element`, or `variants`, rendered as `.name`.
        case member(String)
        /// A backend name such as a field, function path, or table, rendered as `[name]`.
        case key(String)
        /// A position in an ordered list such as union variants, rendered as `[index]`.
        case index(Int)
    }

    /// The steps from the document root.
    public private(set) var components: [Component]

    /// Creates a path from its components.
    public init(_ components: [Component] = []) {
        self.components = components
    }

    /// The path of the function with the given Convex address.
    public static func function(_ path: String) -> ContractPath {
        ContractPath([.member("functions"), .key(path)])
    }

    /// The path of the table with the given backend name.
    public static func table(_ name: String) -> ContractPath {
        ContractPath([.member("tables"), .key(name)])
    }

    /// The path of the named type with the given contract key.
    public static func type(_ name: String) -> ContractPath {
        ContractPath([.member("types"), .key(name)])
    }

    /// The path of the module namespace with the given slash-separated module path.
    public static func module(_ path: String) -> ContractPath {
        ContractPath([.member("modules"), .key(path)])
    }

    /// Returns this path extended by a fixed member.
    public func member(_ name: String) -> ContractPath {
        appending(.member(name))
    }

    /// Returns this path extended by a backend name.
    public func key(_ name: String) -> ContractPath {
        appending(.key(name))
    }

    /// Returns this path extended by a list position.
    public func index(_ position: Int) -> ContractPath {
        appending(.index(position))
    }

    /// Returns this path extended by one component.
    public func appending(_ component: Component) -> ContractPath {
        var copy = self
        copy.components.append(component)
        return copy
    }

    /// The rendered path, escaping `\` and `]` inside bracketed names.
    public var description: String {
        var result = ""
        for component in components {
            switch component {
            case .member(let name):
                if !result.isEmpty {
                    result += "."
                }
                result += name
            case .key(let name):
                result += "["
                for character in name {
                    if character == "\\" || character == "]" {
                        result.append("\\")
                    }
                    result.append(character)
                }
                result += "]"
            case .index(let position):
                result += "[\(position)]"
            }
        }
        return result
    }
}
