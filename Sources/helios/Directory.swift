import Foundation

// Raised for the conditions where the bash version did `exit 0` after a
// warning/error: not authenticated yet, no kerberos cache, ldap failure, etc.
// main() catches this, logs the line, and exits 0 so launchd does not treat
// the run as a failure.
struct DirectoryExit: Error {
    let level: Log.Level
    let message: String
}

enum Directory {
    static let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/helios", isDirectory: true)
    static let groupsCache = cacheDir.appendingPathComponent("ad_groups.txt")
    static let groupsTTL: TimeInterval = 14_400  // 4 h, matches bash

    // MARK: AD groups (recursive), disk-cached

    static func adGroups(realm: String,
                         domain: String,
                         domainPath: String,
                         adUser: String) throws -> [String] {
        // 1. Fresh, non-empty cache wins.
        if let cached = readGroupsCache(), !cached.isEmpty {
            Log.shared.i("Using cached AD groups")
            return cached
        }

        // 2. Kerberos credential cache for this realm.
        guard let kCache = kerberosCache(realm: realm) else {
            throw DirectoryExit(level: .error,
                                message: "No valid Kerberos cache found for realm [\(realm)]")
        }
        Log.shared.i("Using Kerberos cache [\(kCache)]")

        // 3. Resolve the user's distinguishedName.
        let dnRes = Shell.run("/usr/bin/ldapsearch", [
            "-LLL", "-o", "ldif-wrap=no", "-Y", "GSSAPI",
            "-H", "ldap://\(domain)", "-b", domainPath,
            "(&(objectClass=user)(sAMAccountName=\(adUser)))",
            "distinguishedName"
        ], env: ["KRB5CCNAME": kCache])

        if dnRes.status != 0 {
            throw DirectoryExit(level: .error,
                message: "ldapsearch failed resolving DN for [\(adUser)], rc=\(dnRes.status): "
                       + oneLine(dnRes.stdout + dnRes.stderr))
        }
        guard let userDN = ldifValue(of: "distinguishedName", in: dnRes.stdout),
              !userDN.isEmpty else {
            throw DirectoryExit(level: .error,
                message: "Could not resolve distinguishedName for [\(adUser)]: "
                       + oneLine(dnRes.stdout + dnRes.stderr))
        }
        Log.shared.i("Resolved distinguishedName for [\(adUser)]")

        // 4. Recursive group membership (LDAP_MATCHING_RULE_IN_CHAIN).
        let filterDN = escapeForFilter(userDN)
        let grpRes = Shell.run("/usr/bin/ldapsearch", [
            "-LLL", "-o", "ldif-wrap=no", "-Y", "GSSAPI",
            "-H", "ldap://\(domain)", "-b", domainPath,
            "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:=\(filterDN)))",
            "cn"
        ], env: ["KRB5CCNAME": kCache])

        if grpRes.status != 0 {
            throw DirectoryExit(level: .error,
                message: "ldapsearch failed resolving recursive groups for [\(adUser)], rc=\(grpRes.status): "
                       + oneLine(grpRes.stdout + grpRes.stderr))
        }

        let groups = Array(Set(ldifValues(of: "cn", in: grpRes.stdout))).sorted()
        if groups.isEmpty {
            throw DirectoryExit(level: .warn, message: "No AD groups found for [\(adUser)]")
        }
        Log.shared.i("Successfully retrieved [\(groups.count)] AD groups for [\(adUser)]")

        writeGroupsCache(groups)
        return groups
    }

    // MARK: Kerberos cache discovery
    //
    // bash: klist -l | awk 'NR>1 && /@<realm>/ && !/Expired/ { extract API:UUID; exit }'
    static func kerberosCache(realm: String) -> String? {
        let r = Shell.run("/usr/bin/klist", ["-l"])
        guard r.status == 0 else { return nil }

        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }

        let re = try? NSRegularExpression(pattern: "API:[A-F0-9-]+")
        for line in lines.dropFirst() {
            let s = String(line)
            guard s.contains("@\(realm)"), !s.contains("Expired") else { continue }
            if let re,
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let rng = Range(m.range, in: s) {
                return String(s[rng])
            }
        }
        return nil
    }

    // MARK: Deterministic domain controller
    //
    // bash: dig +short ... SRV | sort -k1,1n -k4,4 | awk '{print $4}' | sed 's/\.$//' | head -1
    static func domainController(domain: String) -> String? {
        let r = Shell.run("/usr/bin/dig",
                          ["+short", "_ldap._tcp.dc._msdcs.\(domain)", "SRV"])
        guard r.status == 0 else { return nil }

        struct SRV { let priority: Int; let target: String }
        var records: [SRV] = []
        for line in r.stdout.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 4, let pri = Int(f[0]) else { continue }
            var target = String(f[3])
            if target.hasSuffix(".") { target.removeLast() }
            records.append(SRV(priority: pri, target: target))
        }
        guard !records.isEmpty else { return nil }

        records.sort { a, b in
            a.priority != b.priority ? a.priority < b.priority : a.target < b.target
        }
        return records.first?.target
    }

    // MARK: LDIF parsing helpers

    /// First value of an attribute. Handles "attr: value" and base64 "attr:: b64".
    private static func ldifValue(of attr: String, in ldif: String) -> String? {
        ldifValues(of: attr, in: ldif).first
    }

    private static func ldifValues(of attr: String, in ldif: String) -> [String] {
        var out: [String] = []
        for raw in ldif.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("\(attr):: ") {
                let b64 = String(line.dropFirst(attr.count + 3))
                    .trimmingCharacters(in: .whitespaces)
                if let d = Data(base64Encoded: b64) {
                    out.append(String(decoding: d, as: UTF8.self))
                }
            } else if line.hasPrefix("\(attr): ") {
                out.append(String(line.dropFirst(attr.count + 2))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    /// bash sed order: backslash first, then * ( )
    private static func escapeForFilter(_ dn: String) -> String {
        var s = dn
        s = s.replacingOccurrences(of: "\\", with: "\\5c")
        s = s.replacingOccurrences(of: "*",  with: "\\2a")
        s = s.replacingOccurrences(of: "(",  with: "\\28")
        s = s.replacingOccurrences(of: ")",  with: "\\29")
        return s
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Group cache I/O

    private static func readGroupsCache() -> [String]? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: groupsCache.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < groupsTTL,
              let text = try? String(contentsOf: groupsCache, encoding: .utf8)
        else { return nil }

        return text.split(separator: "\n").map(String.init)
    }

    private static func writeGroupsCache(_ groups: [String]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDir.path) {
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        let body = groups.joined(separator: "\n") + "\n"
        try? body.write(to: groupsCache, atomically: true, encoding: .utf8)
        Log.shared.i("Cached AD groups to [\(groupsCache.path)]")
    }
}
