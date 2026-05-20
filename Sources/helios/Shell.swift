import Foundation

// Thin wrapper around Process. The Kerberos/LDAP path deliberately shells out
// to the system tools (app-sso, klist, ldapsearch, dig) — the same approach
// the previous bash version and the reference ShareMount tool use. These tools
// are stable and handle GSSAPI correctly; reimplementing them natively would
// add risk for no functional gain.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs an executable by absolute path. Optional extra environment is
    /// merged onto the current environment (used to set KRB5CCNAME).
    static func run(_ path: String,
                    _ args: [String],
                    env extra: [String: String] = [:]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        if !extra.isEmpty {
            var e = ProcessInfo.processInfo.environment
            for (k, v) in extra { e[k] = v }
            proc.environment = e
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return Result(
            status: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
