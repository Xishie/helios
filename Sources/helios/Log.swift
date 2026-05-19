import Foundation

// Emits the exact line format the bash version used so existing log tooling
// keeps working:  "<ts> | launchd | <LEVEL> | <pid> | helios | <message>"
// Every line is appended to the log file and echoed to stdout (the bash
// script teed stdout into the log; the LaunchAgent still captures stdout).
final class Log {
    enum Level: String { case info = "I", warn = "W", error = "E" }

    static let shared = Log()

    private let component = "helios"
    private let service = "launchd"
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let logURL: URL
    private let handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs/helios", isDirectory: true)
        self.logURL = dir.appendingPathComponent("helios.log")

        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Rotate: bash deleted the log once it passed 1 MB.
        if let size = try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int,
           size > 1_048_576 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }

        let h = try? FileHandle(forWritingTo: logURL)
        h?.seekToEndOfFile()
        self.handle = h

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        self.formatter = f
    }

    func entry(_ level: Level, _ message: String) {
        let ts = formatter.string(from: Date())
        let line = "\(ts) | \(service) | \(level.rawValue) | \(pid) | \(component) | \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        handle?.write(Data(line.utf8))
    }

    var path: String { logURL.path }

    func i(_ m: String) { entry(.info, m) }
    func w(_ m: String) { entry(.warn, m) }
    func e(_ m: String) { entry(.error, m) }
}
