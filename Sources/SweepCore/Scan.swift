import Foundation
import CryptoKit

public struct FileInfo: Sendable {
    public let path: String
    public let size: Int64
    public let accessed: Date
    public let created: Date
    public var iCloud = false
}

public enum Scan {
    // Tuning knobs. Change here if the lists are too noisy or too quiet.
    public static let minJunk: Int64 = 1_000_000
    public static let largeFile: Int64 = 100_000_000
    public static let oldFileMin: Int64 = 10_000_000
    public static let oldDays = 180
    public static let staleProjectDays = 30
    public static let junkDirNames: Set<String> = ["node_modules", ".next", "DerivedData"]

    static let devCachePaths = [
        ".npm/_cacache", ".yarn/cache", ".pnpm-store", ".bun/install/cache",
        ".gradle/caches", ".cargo/registry/cache",
        "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches",
    ]

    public static func isProtected(_ path: String, running: Set<String>) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        return n.hasPrefix("com.apple.") || running.contains(n)
    }

    /// One row per direct child of each folder, biggest first.
    public static func folderChildren(
        _ dirs: [String], minSize: Int64 = minJunk, skip: (String) -> Bool = { _ in false }
    ) -> [Item] {
        dirs.flatMap { FS.children($0) }
            .filter { !skip($0) }
            .map { Item(path: $0, size: FS.size($0)) }
            .filter { $0.size >= minSize }
            .sorted { $0.size > $1.size }
    }

    public static func systemJunk(home: String = FS.home, running: Set<String>, minSize: Int64 = minJunk) -> [Item] {
        folderChildren([home + "/Library/Caches", home + "/Library/Logs"], minSize: minSize) {
            isProtected($0, running: running)
        }
    }

    public static func adminJunk() -> [Item] {
        folderChildren(["/Library/Caches", "/Library/Logs"]) { isProtected($0, running: []) }
    }

    /// Known package-manager caches, plus (for manual review only) everything in ~/.cache,
    /// which can also hold large downloads such as ML models that are slow to get back.
    public static func devCaches(home: String = FS.home, minSize: Int64 = minJunk, includeDotCache: Bool = true) -> [Item] {
        let fixed = devCachePaths.map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { Item(path: $0, size: FS.size($0), note: "tool cache") }
            .filter { $0.size >= minSize }
        let dot = includeDotCache ? folderChildren([home + "/.cache"], minSize: minSize) : []
        return (fixed + dot).sorted { $0.size > $1.size }
    }

    public static func devJunk(home: String = FS.home, projects: String) -> [Item] {
        (devCaches(home: home) + staleBuildDirs(root: projects).filter { $0.size >= minJunk })
            .sorted { $0.size > $1.size }
    }

    /// Rebuildable folders (node_modules etc.) inside projects nobody has touched lately.
    public static func staleBuildDirs(
        root: String, days: Int = staleProjectDays, now: Date = Date(), maxDepth: Int = 5
    ) -> [Item] {
        var out: [Item] = []
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        func walk(_ dir: String, _ depth: Int) {
            for child in FS.children(dir) where FS.isDir(child) {
                let name = (child as NSString).lastPathComponent
                if junkDirNames.contains(name) {
                    let touched = lastTouched(dir)
                    if touched < cutoff {
                        out.append(Item(path: child, size: FS.size(child), note: "project untouched since " + FS.day(touched)))
                    }
                } else if !name.hasPrefix("."), depth < maxDepth {
                    walk(child, depth + 1)
                }
            }
        }
        walk(root, 0)
        return out.sorted { $0.size > $1.size }
    }

    // ponytail: only looks two levels deep, so an edit buried deeper is missed.
    // Upgrade path: read `git log -1` date when the project is a repo.
    static func lastTouched(_ project: String) -> Date {
        var newest = Date.distantPast
        for child in FS.children(project) {
            let name = (child as NSString).lastPathComponent
            if junkDirNames.contains(name) || name == ".DS_Store" { continue }
            newest = max(newest, FS.mtime(child))
            if FS.isDir(child) {
                for grandchild in FS.children(child) { newest = max(newest, FS.mtime(grandchild)) }
            }
        }
        return newest
    }

    /// Regular, locally stored files. Hidden files, app bundles' insides and iCloud-only files are skipped.
    public static func files(in dirs: [String]) -> [FileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .creationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var out: [FileInfo] = []
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in walker {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                // iCloud files count only when downloaded; reading an iCloud-only one would trigger a download.
                if v.isUbiquitousItem == true, v.ubiquitousItemDownloadingStatus != .current { continue }
                out.append(FileInfo(
                    path: url.path, size: Int64(v.fileSize ?? 0),
                    accessed: v.contentAccessDate ?? .distantPast, created: v.creationDate ?? .distantPast,
                    iCloud: v.isUbiquitousItem == true))
            }
        }
        return out
    }

    public static func largeOld(
        _ dirs: [String], large: Int64 = largeFile, oldMin: Int64 = oldFileMin, days: Int = oldDays, now: Date = Date()
    ) -> [Item] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return files(in: dirs).compactMap { f -> Item? in
            let old = f.accessed < cutoff && f.size >= oldMin
            guard f.size >= large || old else { return nil }
            return Item(path: f.path, size: f.size, note: (old ? "last opened " + FS.day(f.accessed) : "large file") + iCloudNote(f))
        }.sorted { $0.size > $1.size }
    }

    public static func duplicates(_ dirs: [String], minSize: Int64 = minJunk) -> [Item] {
        var seen = Set<String>()   // device:inode, so hard links to one file are not "duplicates"
        let unique = files(in: dirs).filter { $0.size >= minSize }.filter { f in
            var st = stat()
            guard lstat(f.path, &st) == 0 else { return true }
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
        let bySize = Dictionary(grouping: unique, by: \.size)
            .filter { $0.value.count > 1 }
        var out: [Item] = []
        for (size, sameSize) in bySize.sorted(by: { $0.key > $1.key }) {
            let byHash = Dictionary(grouping: sameSize) { hash($0.path) ?? UUID().uuidString }
            for (digest, same) in byHash where same.count > 1 {
                for (i, f) in same.sorted(by: { ($0.created, $0.path) < ($1.created, $1.path) }).enumerated() {
                    out.append(Item(path: f.path, size: size,
                                    note: (i == 0 ? "original (oldest)" : "duplicate") + iCloudNote(f), group: String(digest.prefix(8))))
                }
            }
        }
        return out
    }

    /// Removing an iCloud Drive file removes it from every device, so say so on the row.
    static func iCloudNote(_ f: FileInfo) -> String { f.iCloud ? " · in iCloud, removes it on all devices" : "" }

    /// Duplicate groups in which every copy is selected. Trashing those would leave no original.
    public static func wholeGroups(_ selected: [Item], of all: [Item]) -> Set<String> {
        let picked = Set(selected.map(\.path))
        return Set(Dictionary(grouping: all.filter { !$0.group.isEmpty }, by: \.group)
            .filter { $0.value.allSatisfy { picked.contains($0.path) } }.keys)
    }

    static func hash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
