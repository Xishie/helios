import Foundation
import NetFS
import Darwin

// Mounts via the NetFS framework directly (NetFSMountURLSync), NOT Finder /
// `mount volume`. Two consequences vs the osascript approach:
//
//  * the NoUI option makes NetFS *return an error instead of prompting* — no
//    first-connect dialog, ever (silent success with Kerberos, silent failure
//    without);
//  * the resulting mount is not Finder-adopted, so a VPN drop behaves like the
//    old mount_smbfs mounts (a single DiskArbitration notification) instead of
//    a reconnect dialog per share.
//
// NetFS still follows the full Windows DFS referral chain, because it is the
// same engine Finder uses.
enum Mounter {

    // NetFS option keys/values. They are CFSTR(...) #define macros in
    // <NetFS/NetFS.h> and are not surfaced as Swift symbols, so the literal
    // string values from the header are used directly.
    private static let kUIOption   = "UIOption"
    private static let kNoUI       = "NoUI"
    private static let kGuest      = "Guest"
    private static let kSoftMount  = "SoftMount"

    /// Volume name NetFS will use: last path component of the URL.
    /// smb://host/srf-tpc/EFS -> "EFS"  (stable regardless of which DC).
    static func volumeName(for url: String) -> String {
        var s = url
        if s.hasSuffix("/") { s.removeLast() }
        return String(s.split(separator: "/").last ?? "")
    }

    static func mount(_ url: String) {
        let name = volumeName(for: url)
        let mountpoint = "/Volumes/\(name)"

        if isMounted(mountpoint: mountpoint, url: url) {
            Log.shared.i("Already mounted [\(mountpoint)], skipping")
            return
        }

        guard let cfURL = makeURL(url) else {
            Log.shared.e("Could not build URL from [\(url)]")
            return
        }

        let openOptions = NSMutableDictionary()
        openOptions[kUIOption] = kNoUI      // never show UI; error instead
        openOptions[kGuest] = false         // force Kerberos, not guest

        let mountOptions = NSMutableDictionary()
        mountOptions[kSoftMount] = true     // dead server fails fast, no hang

        Log.shared.i("Mounting [\(url)] via NetFS to [\(mountpoint)]")

        let rc = NetFSMountURLSync(
            cfURL as CFURL,
            nil,                            // default mountpoint (/Volumes/<name>)
            nil,                            // user  -> Kerberos identity
            nil,                            // passwd
            openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary,
            nil
        )

        if rc == 0 {
            Log.shared.i("Mount successful for [\(mountpoint)]")
        } else {
            Log.shared.e("NetFS mount failed for [\(url)] (\(describe(rc)))")
        }
    }

    // MARK: URL construction
    //
    // CFURL needs a well-formed URL; share/path components may contain
    // characters like '$' or spaces. Percent-encode host and path while
    // keeping the smb:// scheme.
    private static func makeURL(_ raw: String) -> URL? {
        guard raw.hasPrefix("smb://") else { return URL(string: raw) }
        let rest = String(raw.dropFirst("smb://".count))
        guard let slash = rest.firstIndex(of: "/") else {
            return URL(string: raw)
        }
        let host = String(rest[..<slash])
        let path = String(rest[slash...])              // begins with "/"

        let encHost = host.addingPercentEncoding(
            withAllowedCharacters: .urlHostAllowed) ?? host
        let encPath = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "smb://\(encHost)\(encPath)")
    }

    // MARK: mount table inspection

    private static func isMounted(mountpoint: String, url: String) -> Bool {
        var raw: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&raw, MNT_NOWAIT)
        guard count > 0, let buf = raw else { return false }

        // host/share of the requested URL, lowercased, for the from-name check.
        let want = url
            .replacingOccurrences(of: "smb://", with: "")
            .lowercased()

        for i in 0..<Int(count) {
            let fs = buf[i]
            let on = withCString(fs.f_mntonname)
            if on == mountpoint { return true }

            // f_mntfromname looks like //user@host/share/path; if the same
            // share is already mounted (e.g. under a -1 suffix), skip too.
            let from = withCString(fs.f_mntfromname).lowercased()
            if let at = from.range(of: "@") {
                let hostShare = String(from[at.upperBound...])
                if !hostShare.isEmpty, want.hasPrefix(hostShare) || hostShare == want {
                    return true
                }
            }
        }
        return false
    }

    /// Convert a statfs fixed C-char array member to a Swift String.
    private static func withCString<T>(_ tuple: T) -> String {
        var t = tuple
        return withUnsafePointer(to: &t) {
            $0.withMemoryRebound(to: CChar.self,
                                 capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
    }

    /// Render the NetFSMountURLSync return code: 0 ok, >0 errno, <0 OSStatus.
    private static func describe(_ rc: Int32) -> String {
        if rc > 0 {
            return "errno=\(rc) \(String(cString: strerror(rc)))"
        }
        return "OSStatus=\(rc)"
    }
}
