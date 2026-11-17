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

    /// Build cache and images no container uses. Never containers or volumes: those can hold databases.
    public static let pruneCommands = [["builder", "prune", "-f"], ["image", "prune", "-a", "-f"]]

    public static func prune() -> String {
        guard let bin = binary else { return "Docker is not installed." }
        let totals = pruneCommands.map { args -> String in
            let r = Shell.run(bin, args)
            let last = r.out.split(separator: "\n").last { $0.contains("Total") }.map(String.init) ?? r.out
            return last.components(separatedBy: CharacterSet(charactersIn: ":\t")).last?
                .trimmingCharacters(in: .whitespaces) ?? "?"
        }
        return "Docker freed \(totals[0]) of build cache and \(totals[1]) of unused images."
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

    /// Background services the app's developer installed system-wide (outside ~/Library). Sweep only reports
    /// these: removing them safely needs the app's own uninstaller.
    public static func systemComponents(_ app: AppInfo, roots: [String] = [
        "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools",
    ]) -> [String] {
        let parts = app.bundleID.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return [] }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        return roots.flatMap { FS.children($0) }
            .filter { ($0 as NSString).lastPathComponent.lowercased().hasPrefix(vendor) }
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
    /// Presets for `Sweep --schedule off|daily|weekly`.
    public enum Mode: String, CaseIterable, Sendable { case off, daily, weekly }

    public struct Config: Equatable, Sendable {
        public var on = false
        public var weekly = true
        public var weekday = 0   // launchd numbering: 0 = Sunday … 6 = Saturday
        public var hour = 12
        public var minute = 0

        public init(on: Bool = false, weekly: Bool = true, weekday: Int = 0, hour: Int = 12, minute: Int = 0) {
            (self.on, self.weekly, self.weekday, self.hour, self.minute) = (on, weekly, weekday, hour, minute)
        }

        public init(_ mode: Mode) { self.init(on: mode != .off, weekly: mode != .daily) }

        /// Same schedule in effect: settings hidden while off, or the day while daily, don't count.
        public func same(as o: Config) -> Bool {
            on == o.on && (!on || (weekly == o.weekly && hour == o.hour && minute == o.minute && (!weekly || weekday == o.weekday)))
        }
    }

    public static let label = "com.sweep.autoclean"
    public static var plistPath: String { FS.home + "/Library/LaunchAgents/\(label).plist" }

    public static func plist(binary: String, config: Config) -> [String: Any] {
        var when = ["Hour": config.hour, "Minute": config.minute]
        if config.weekly { when["Weekday"] = config.weekday }
        return ["Label": label, "ProgramArguments": [binary, "--auto-clean"], "StartCalendarInterval": when]
    }

    public static func current(path: String = plistPath) -> Config {
        guard let d = NSDictionary(contentsOfFile: path),
              let when = d["StartCalendarInterval"] as? [String: Int] else { return Config() }
        return Config(on: true, weekly: when["Weekday"] != nil, weekday: (when["Weekday"] ?? 0) % 7,
                      hour: when["Hour"] ?? 12, minute: when["Minute"] ?? 0)
    }

    public static func set(_ config: Config, binary: String) -> String {
        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        guard config.on else { return "Automatic cleaning is off." }
        try? FileManager.default.createDirectory(atPath: FS.home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        guard (plist(binary: binary, config: config) as NSDictionary).write(toFile: plistPath, atomically: true) else {
            return "Could not write the schedule file."
        }
        let r = Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath])
        return r.status == 0 ? "Schedule saved." : "Could not register the schedule. \(r.out)"
    }

    /// Next run after `now`, nil when off.
    public static func nextRun(_ c: Config, after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard c.on else { return nil }
        var when = DateComponents(hour: c.hour, minute: c.minute)
        if c.weekly { when.weekday = c.weekday + 1 }   // Calendar numbering: 1 = Sunday
        return calendar.nextDate(after: now, matching: when, matchingPolicy: .nextTime)
    }
}

public enum AutoClean {
    /// Headless run for the schedule: caches and logs only, deleted permanently.
    public static func run(home: String = FS.home, running: Set<String>) -> CleanResult {
        let items = Scan.systemJunk(home: home, running: running) + Scan.devCaches(home: home)
        return Cleaner.trash(items, home: home) { try FileManager.default.removeItem(at: $0) }
    }
}
