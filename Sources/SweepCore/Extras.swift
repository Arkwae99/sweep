import Foundation
import Darwin

// MARK: Memory

public struct Proc: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let rss: Int64
    public let path: String
    public var id: Int32 { pid }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum Memory {
    public static func usage() -> (used: Int64, total: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return (pages * Int64(sysconf(_SC_PAGESIZE)), total)
    }

    public static func parsePS(_ out: String) -> [Proc] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let kb = Int64(parts[1]) else { return nil }
            return Proc(pid: pid, rss: kb * 1024, path: String(parts[2]))
        }
    }

    /// The current user's processes, heaviest first.
    public static func top(_ n: Int = 25) -> [Proc] {
        Array(parsePS(Shell.run("/bin/ps", ["-xo", "pid=,rss=,comm="]).out).sorted { $0.rss > $1.rss }.prefix(n))
    }

    public static func quit(_ pid: Int32) { kill(pid, SIGTERM) }

    public static func purge() -> String {
        let r = Shell.run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"])
        return r.status == 0 ? "Inactive memory purged." : "Cancelled or failed. \(r.out)"
    }
}

// MARK: Docker

public enum Docker {
    public static var binary: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func usage() -> String {
        guard let bin = binary else { return "Docker is not installed." }
        let r = Shell.run(bin, ["system", "df"])
        return r.status == 0 ? r.out : "Docker is not running.\n\(r.out)"
    }

    /// Removes stopped containers, unused networks, dangling images and build cache. Volumes are kept.
    public static func prune() -> String {
        guard let bin = binary else { return "Docker is not installed." }
        return Shell.run(bin, ["system", "prune", "-f"]).out
    }
}

// MARK: App uninstaller

public struct AppInfo: Identifiable, Hashable, Sendable {
    public let path: String
    public let bundleID: String
    public let size: Int64
    public var id: String { path }
    public var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

public enum Apps {
    public static func list(dirs: [String] = ["/Applications", FS.home + "/Applications"]) -> [AppInfo] {
        dirs.flatMap { FS.children($0) }.filter { $0.hasSuffix(".app") }.compactMap { path -> AppInfo? in
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
                  let id = info["CFBundleIdentifier"] as? String,
                  !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier else { return nil }
            return AppInfo(path: path, bundleID: id, size: FS.size(path))
        }.sorted { $0.size > $1.size }
    }

    /// Support files named exactly after the app or its bundle ID. No fuzzy matching.
    public static func leftovers(_ app: AppInfo, home: String = FS.home) -> [Item] {
        let lib = home + "/Library/"
        return [
            "Application Support/\(app.name)", "Application Support/\(app.bundleID)",
            "Caches/\(app.bundleID)", "Preferences/\(app.bundleID).plist", "Logs/\(app.name)",
            "Saved Application State/\(app.bundleID).savedState", "Containers/\(app.bundleID)",
            "HTTPStorages/\(app.bundleID)", "WebKit/\(app.bundleID)", "Cookies/\(app.bundleID).binarycookies",
        ].map { lib + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { Item(path: $0, size: FS.size($0)) }
    }
}

// MARK: Scheduled cleaning

public enum Schedule {
    public enum Mode: String, CaseIterable, Sendable { case off, daily, weekly }

    public static let label = "com.sweep.autoclean"
    public static var plistPath: String { FS.home + "/Library/LaunchAgents/\(label).plist" }

    public static func plist(binary: String, mode: Mode) -> [String: Any] {
        var when: [String: Int] = ["Hour": 12, "Minute": 0]
        if mode == .weekly { when["Weekday"] = 1 }
        return ["Label": label, "ProgramArguments": [binary, "--auto-clean"], "StartCalendarInterval": when]
    }

    public static func current() -> Mode {
        guard let d = NSDictionary(contentsOfFile: plistPath),
              let when = d["StartCalendarInterval"] as? [String: Int] else { return .off }
        return when["Weekday"] == nil ? .daily : .weekly
    }

    public static func set(_ mode: Mode, binary: String) -> String {
        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        guard mode != .off else { return "Scheduled cleaning is off." }
        try? FileManager.default.createDirectory(atPath: FS.home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        guard (plist(binary: binary, mode: mode) as NSDictionary).write(toFile: plistPath, atomically: true) else {
            return "Could not write the schedule file."
        }
        let r = Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath])
        return r.status == 0 ? "Runs \(mode.rawValue) at 12:00." : "Could not register the schedule. \(r.out)"
    }
}

public enum AutoClean {
    /// Headless run for the schedule: caches and logs only, deleted permanently.
    public static func run(home: String = FS.home, running: Set<String>) -> CleanResult {
        let items = Scan.systemJunk(home: home, running: running) + Scan.devCaches(home: home)
        return Cleaner.trash(items, home: home) { try FileManager.default.removeItem(at: $0) }
    }
}
