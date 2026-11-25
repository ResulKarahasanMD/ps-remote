import Foundation

/// Reuses a registration chiaki-ng already made, read from its preferences
/// (`registered_hosts.<n>.*` keys in ~/Library/Preferences/com.chiaki.Chiaki.plist).
public enum ChiakiNGImport {
    public enum ImportError: Error, Equatable {
        case noRegisteredHosts
        case malformed(index: Int, field: String)
        case unreadable(String)
    }

    public static var defaultPreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.chiaki.Chiaki.plist")
    }

    public static func loadPreferences(at url: URL = defaultPreferencesURL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard let prefs = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw ImportError.unreadable(url.path) }
            return prefs
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadable(url.path)
        }
    }

    /// `addresses` maps host ID → current LAN address (from discovery); unknown hosts get "".
    public static func consoles(fromPreferences prefs: [String: Any], addresses: [String: String]) throws -> [RegisteredConsole] {
        let count = (prefs["registered_hosts.size"] as? Int) ?? 0
        guard count > 0 else { throw ImportError.noRegisteredHosts }
        return try (1...count).map { index in
            func value<T>(_ field: String, as type: T.Type) throws -> T {
                guard let value = prefs["registered_hosts.\(index).\(field)"] as? T else {
                    throw ImportError.malformed(index: index, field: field)
                }
                return value
            }
            let mac = try value("server_mac", as: Data.self)
            let registKey = try value("rp_regist_key", as: Data.self)
            let rpKey = try value("rp_key", as: Data.self)
            guard mac.count == 6 else { throw ImportError.malformed(index: index, field: "server_mac") }
            guard registKey.count == 16 else { throw ImportError.malformed(index: index, field: "rp_regist_key") }
            guard rpKey.count == 16 else { throw ImportError.malformed(index: index, field: "rp_key") }
            let hostID = mac.map { String(format: "%02X", $0) }.joined()
            return RegisteredConsole(hostID: hostID,
                                     nickname: try value("server_nickname", as: String.self),
                                     lastKnownAddress: addresses[hostID] ?? "",
                                     target: UInt32(try value("target", as: Int.self)),
                                     registKey: registKey,
                                     rpKeyType: UInt32(try value("rp_key_type", as: Int.self)),
                                     rpKey: rpKey,
                                     consolePin: consolePin(prefs["registered_hosts.\(index).console_pin"]))
        }
    }

    /// chiaki-ng stores the PSN account ID as base64 under `settings.psn_account_id`.
    public static func accountID(fromPreferences prefs: [String: Any]) throws -> PSNAccountID? {
        guard let raw = prefs["settings.psn_account_id"] as? String, !raw.isEmpty else { return nil }
        return try PSNAccountID(base64: raw)
    }

    private static func consolePin(_ raw: Any?) -> UInt32 {
        if let number = raw as? Int { return UInt32(clamping: number) }
        if let text = raw as? String, let number = UInt32(text) { return number }
        return 0
    }
}
