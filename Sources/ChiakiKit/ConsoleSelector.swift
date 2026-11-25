public enum ConsoleSelector {
    public enum SelectionError: Error, Equatable {
        case notFound(String)
        case ambiguous([String])
    }

    /// Upper-case hex digits only: "50aa-bbcc:ddee" → "50AABBCCDDEE".
    public static func normalizedID(_ id: String) -> String {
        id.uppercased().filter { $0.isHexDigit }
    }

    /// Picks a console by name, host ID or address (case-insensitive). Without a query,
    /// succeeds only if exactly one console is present.
    public static func select(_ query: String?, from consoles: [Console]) throws -> Console {
        guard let query, !query.isEmpty else {
            if consoles.count == 1 { return consoles[0] }
            if consoles.isEmpty { throw SelectionError.notFound("") }
            throw SelectionError.ambiguous(consoles.map(\.name).sorted())
        }
        let lowered = query.lowercased()
        let matches = consoles.filter {
            $0.name.lowercased() == lowered
                || normalizedID($0.id) == normalizedID(query) && !normalizedID(query).isEmpty
                || $0.address == query
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw SelectionError.notFound(query)
        default: throw SelectionError.ambiguous(matches.map(\.name).sorted())
        }
    }

    /// Current address for a registered console: the discovered one with the same host ID, else the stored one.
    public static func address(for registered: RegisteredConsole, discovered: [Console]) -> String {
        discovered.first { normalizedID($0.id) == registered.hostID }?.address ?? registered.lastKnownAddress
    }
}
