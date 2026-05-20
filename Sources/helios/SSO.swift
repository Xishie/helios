import Foundation

// Equivalent of:
//   kssoeState=$(app-sso -i "$realm" -j | jq -r '.upn // empty')
//   netState=$(app-sso  -i "$realm" -j | jq -r '.networkAvailable // empty')
//   adUser=$(echo "$kssoeState" | cut -d'@' -f1)
//
// jq's `// empty` yields empty only when the value is null or false, so a
// present truthy value (string / true / number) counts as set.
struct SSOState {
    let upn: String
    let networkAvailable: Bool
    var adUser: String { upn.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "" }

    static func load(realm: String) -> SSOState {
        let r = Shell.run("/usr/bin/app-sso", ["-i", realm, "-j"])
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return SSOState(upn: "", networkAvailable: false)
        }

        // `.upn // empty`: empty if null/false/absent.
        var upn = ""
        if let s = obj["upn"] as? String { upn = s }

        // `.networkAvailable // empty`: set unless null or false.
        var net = false
        if let v = obj["networkAvailable"] {
            if let b = v as? Bool { net = b }
            else if v is NSNull { net = false }
            else if let s = v as? String { net = !s.isEmpty }
            else { net = true } // numbers / other truthy
        }

        return SSOState(upn: upn, networkAvailable: net)
    }
}
