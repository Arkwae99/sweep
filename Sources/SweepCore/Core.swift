import Foundation

public struct Item: Identifiable, Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let note: String
    public let group: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, size: Int64, note: String = "", group: String = "") {
        self.path = path
        self.size = size
        self.note = note
        self.group = group
    }
}

public struct CleanResult: Sendable {
    public var freed: Int64 = 0
    public var done: [String] = []
    public var failures: [String] = []
    public init() {}
}

public enum FS {
    public static let home = NSHomeDirectory()

    public static func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
    }

    public static func readable(_ dir: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) != nil
    }

    /// True for real directories only; a symlink to a directory is not followed.
    public static func isDir(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    public static func mtime(_ path: String) -> Date {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Disk space used by a file or a whole directory tree. Symlinks are not followed.
    public static func size(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let own = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        guard isDir(path),
              let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [], errorHandler: { _, _ in true })
        else { return own }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func day(_ date: Date) -> String {
        date == .distantPast ? "unknown" : date.formatted(date: .abbreviated, time: .omitted)
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The only gate between a scan result and a deletion. Everything destructive passes through here.
public enum Safety {
    public static func std(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }

    public static func canTrash(_ path: String, home: String = FS.home) -> Bool {
        let p = std(path), h = std(home)
        if p.hasPrefix("/Applications/") {
            return p.hasSuffix(".app") && p.split(separator: "/").count == 2
        }
        guard p.hasPrefix(h + "/") else { return false }
        let rel = p.dropFirst(h.count + 1).split(separator: "/")
        if rel.count < 2 { return false }                         // never ~/Documents itself
        if rel[0] == "Library" && rel.count < 3 { return false }  // never ~/Library/Caches itself
        return true
    }

    public static func canAdminDelete(_ path: String) -> Bool {
        let p = std(path)
        return ["/Library/Caches/", "/Library/Logs/"].contains { p.hasPrefix($0) && p.count > $0.count }
    }
}

public enum Cleaner {
    public static func trash(
        _ items: [Item], home: String = FS.home,
        mover: (URL) throws -> Void = defaultMover
    ) -> CleanResult {
        var r = CleanResult()
        for item in items {
            guard Safety.canTrash(item.path, home: home) else {
                r.failures.append("\(item.path): outside the allowed folders")
                continue
            }
            do {
                try mover(URL(fileURLWithPath: Safety.std(item.path)))   // act on the path the gate checked
                r.freed += item.size
                r.done.append(item.path)
            } catch {
                r.failures.append("\(item.path): \(error.localizedDescription)")
            }
        }
        return r
    }

    /// Moves to the Trash; if macOS refuses (an app installed by a package is owned by root), asks Finder,
    /// which shows its own password prompt, exactly like dragging the item to the Trash by hand.
    public static func defaultMover(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            // Finder resolves symlinks, so never hand it one. macOS reports root-owned items with varying
            // error codes, so any other failure on a real item gets the Finder (password prompt) retry.
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            guard !isLink, FileManager.default.fileExists(atPath: url.path) else { throw error }
            let r = Shell.run("/usr/bin/osascript", ["-e", finderTrashScript(url.path)])
            if r.status != 0 { throw error }
        }
    }

    /// The app first; its leftovers only if the app really went, so a cancelled password prompt
    /// never leaves an installed app with its settings and data gone.
    public static func uninstall(app: Item, leftovers: [Item], home: String = FS.home,
                                 mover: (URL) throws -> Void = defaultMover) -> CleanResult {
        var r = trash([app], home: home, mover: mover)
        guard r.done.contains(app.path) else { return r }
        let rest = trash(leftovers, home: home, mover: mover)
        r.done += rest.done
        r.freed += rest.freed
        r.failures += rest.failures
        return r
    }

    public static func finderTrashScript(_ path: String) -> String {
        let p = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Finder\" to delete (POSIX file \"\(p)\" as alias)"
    }

    /// AppleScript that removes the paths as root. macOS shows the password prompt; we never see it.
    public static func adminScript(_ paths: [String]) -> String {
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let cmd = ("/bin/rm -rf -- " + quoted)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(cmd)\" with administrator privileges"
    }

    public static func adminDelete(_ items: [Item]) -> CleanResult {
        var r = CleanResult()
        // Items already gone are done (they leave the list) but free nothing.
        let gone = items.filter { Safety.canAdminDelete($0.path) && !FileManager.default.fileExists(atPath: $0.path) }
        let allowed = items.filter { Safety.canAdminDelete($0.path) && FileManager.default.fileExists(atPath: $0.path) }
        r.done = gone.map(\.path)
        r.failures = items.filter { !Safety.canAdminDelete($0.path) }.map { "\($0.path): not an allowed system location" }
        guard !allowed.isEmpty else { return r }
        let res = Shell.run("/usr/bin/osascript", ["-e", adminScript(allowed.map { Safety.std($0.path) })])
        for item in allowed {
            if FileManager.default.fileExists(atPath: Safety.std(item.path)) {
                r.failures.append("\(item.path): not removed")
            } else {
                r.freed += item.size
                r.done.append(item.path)
            }
        }
        if res.status != 0 && r.done.count == gone.count { r.failures.append("Cancelled or failed. \(res.out)") }
        return r
    }
}
