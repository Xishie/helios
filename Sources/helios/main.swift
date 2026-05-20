import Foundation
import Darwin

// Every early-out exits 0 so launchd never marks the run as failed; the
// LaunchAgent simply tries again on its next interval.

let log = Log.shared
log.i("Logging execution of [helios] to [\(log.path)]")

// --- single-instance lock ---
//
// The lock must be released on *every* exit path. Swift `defer` does NOT run
// when exit() is called, and exit(0) is used for all the not-ready early-outs
// (network down, not authenticated, ...). So cleanup is registered with
// atexit(), which does run on exit(). As an extra safeguard the lock records
// its owner PID and a lock whose owner is no longer alive (kill -9, panic,
// power loss) is reclaimed rather than blocking forever.
let lockDir = "/tmp/helios.lock"
let lockPidFile = lockDir + "/pid"

func releaseLock() {
    try? FileManager.default.removeItem(atPath: lockDir)
}

func processAlive(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM        // exists but not signalable -> alive
}

func acquireLock() -> Bool {
    let fm = FileManager.default

    func makeLock() -> Bool {
        guard (try? fm.createDirectory(atPath: lockDir,
                                       withIntermediateDirectories: false)) != nil
        else { return false }
        try? "\(getpid())".write(toFile: lockPidFile,
                                 atomically: true, encoding: .utf8)
        atexit { releaseLock() }
        return true
    }

    if makeLock() { return true }

    // Lock exists — only honour it if its owner is still running.
    var ownerPid: Int32 = -1
    if let s = try? String(contentsOfFile: lockPidFile, encoding: .utf8),
       let p = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
        ownerPid = p
    }
    if processAlive(ownerPid) { return false }

    log.w("Reclaiming stale lock (owner pid \(ownerPid) not running)")
    try? fm.removeItem(atPath: lockDir)
    return makeLock()
}

if !acquireLock() {
    log.i("Another instance is already running, exiting")
    exit(0)
}

func finish() -> Never {
    log.i("Fininshed logging execution of [helios] to [\(log.path)]")
    exit(0)   // atexit releases the lock
}

// --- preferences ---
let prefs: Preferences
do {
    prefs = try Preferences.load()
} catch Preferences.LoadError.missing {
    log.w("Configuration profile preferences is not present under \(Preferences.path)")
    exit(0)
} catch Preferences.LoadError.incomplete(let key) {
    switch key {
    case "realm":      log.w("No realm found in preferences plist (key :realm), exiting")
    case "domain":     log.w("No domain found in preferences plist (key :domain), exiting")
    case "domainPath": log.w("No domainPath found in preferences plist (key :domainPath), exiting")
    default:           log.w("Preferences plist unreadable (\(key)), exiting")
    }
    exit(0)
} catch {
    log.w("Preferences plist unreadable, exiting")
    exit(0)
}
log.i("Configuration profile preferences found under \(Preferences.path)")
log.i("Loaded environment from preferences, realm=[\(prefs.realm)], domain=[\(prefs.domain)]")

// --- KSSOE state ---
let sso = SSOState.load(realm: prefs.realm)

if !sso.networkAvailable {
    log.w("Corporate network is not available for the Kerberos Single Sign On Extension, exiting")
    exit(0)
}
log.i("Corporate network is available for the Kerberos Single Sign On Extension")

if sso.upn.isEmpty {
    log.w("User is not authenticated through the Kerberos Single Sign On Extension, exiting")
    exit(0)
}
log.i("User is authenticated through the Kerberos Single Sign On Extension")

let adUser = sso.adUser

// --- AD groups (recursive, cached) ---
let groups: Set<String>
do {
    groups = Set(try Directory.adGroups(
        realm: prefs.realm,
        domain: prefs.domain,
        domainPath: prefs.domainPath,
        adUser: adUser))
} catch let exitErr as DirectoryExit {
    log.entry(exitErr.level, exitErr.message)
    exit(0)
} catch {
    log.e("Unexpected error resolving AD groups: \(error)")
    exit(0)
}

// --- shares ---
if prefs.shares.isEmpty {
    log.w("No shares found in plist [\(Preferences.path)]")
    exit(0)
}
log.i("Found [\(prefs.shares.count)] share entries in plist")

let placeholder = "<<domaincontroller>>"

for (index, share) in prefs.shares.enumerated() {
    if share.url.isEmpty {
        log.w("Share index [\(index)] missing URL, skipping")
        continue
    }

    var url = share.url
    if url.contains(placeholder) {
        guard let dc = Directory.domainController(domain: prefs.domain) else {
            log.w("Could not resolve URL for share index [\(index)], skipping")
            continue
        }
        url = url.replacingOccurrences(of: placeholder, with: dc)
    }

    let authorized = share.groups.contains { groups.contains($0) }
    if authorized {
        log.i("User [\(adUser)] authorized for share [\(url)]")
        Mounter.mount(url)
    } else {
        log.i("User [\(adUser)] not authorized for share [\(url)], skipping")
    }
}

finish()
