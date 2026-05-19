import Foundation

struct Share {
    let url: String
    let groups: [String]
}

// Mirrors the bash version: read the managed-preferences plist file directly
// (not via CFPreferences) so behaviour matches PlistBuddy on the same path.
struct Preferences {
    static let path = "/Library/Managed Preferences/io.github.xishie.helios.plist"

    let realm: String
    let domain: String
    let domainPath: String
    let shares: [Share]

    enum LoadError: Error {
        case missing            // plist absent  -> exit 0 (warn)
        case incomplete(String) // required key empty -> exit 0 (warn)
    }

    static func load() throws -> Preferences {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw LoadError.missing }

        guard let data = fm.contents(atPath: path),
              let root = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            throw LoadError.incomplete("plist unreadable")
        }

        func str(_ key: String) -> String {
            (root[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let realm = str("realm")
        let domain = str("domain")
        let domainPath = str("domainPath")

        if realm.isEmpty { throw LoadError.incomplete("realm") }
        if domain.isEmpty { throw LoadError.incomplete("domain") }
        if domainPath.isEmpty { throw LoadError.incomplete("domainPath") }

        var shares: [Share] = []
        if let rawShares = root["shares"] as? [[String: Any]] {
            for entry in rawShares {
                let url = (entry["URL"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let groups = (entry["groups"] as? [String]) ?? []
                shares.append(Share(url: url, groups: groups))
            }
        }

        return Preferences(realm: realm, domain: domain,
                           domainPath: domainPath, shares: shares)
    }
}
