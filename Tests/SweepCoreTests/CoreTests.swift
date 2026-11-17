import Foundation
import Testing
@testable import SweepCore

/// A throwaway folder that stands in for the home directory.
func makeHome() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func write(_ path: String, bytes: Int = 10, fill: UInt8 = 7, modified: Date? = nil) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(repeating: fill, count: bytes).write(to: URL(fileURLWithPath: path))
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
}

@Test func trashGate() {
    let h = "/Users/x"
    #expect(Safety.canTrash("/Users/x/Library/Caches/com.foo", home: h))
    #expect(Safety.canTrash("/Users/x/Downloads/big.dmg", home: h))
    #expect(Safety.canTrash("/Users/x/.npm/_cacache", home: h))
    #expect(Safety.canTrash("/Applications/Foo.app", home: h))
    #expect(!Safety.canTrash("/Users/x", home: h))
    #expect(!Safety.canTrash("/Users/x/Documents", home: h))
    #expect(!Safety.canTrash("/Users/x/Library/Caches", home: h))
    #expect(!Safety.canTrash("/Users/x/Downloads/../../y/file", home: h))
    #expect(!Safety.canTrash("/Users/xy/Downloads/file", home: h))
    #expect(!Safety.canTrash("/Applications", home: h))
    #expect(!Safety.canTrash("/Applications/Foo.app/Contents", home: h))
    #expect(!Safety.canTrash("/etc/hosts", home: h))
    #expect(!Safety.canTrash("/", home: h))
}

@Test func adminGate() {
    #expect(Safety.canAdminDelete("/Library/Caches/com.foo"))
    #expect(Safety.canAdminDelete("/Library/Logs/foo.log"))
    #expect(!Safety.canAdminDelete("/Library/Caches"))
    #expect(!Safety.canAdminDelete("/Library/Caches/"))
    #expect(!Safety.canAdminDelete("/Library/Caches/../Preferences"))
    #expect(!Safety.canAdminDelete("/Library/Preferences/x"))
    #expect(!Safety.canAdminDelete("/System/Library/Caches/x"))
}

@Test func adminScriptQuoting() {
    let s = Cleaner.adminScript(["/Library/Caches/it's \"x\""])
    #expect(s == #"do shell script "/bin/rm -rf -- '/Library/Caches/it'\\''s \"x\"'" with administrator privileges"#)
}

@Test func adminDeleteRefusesOtherPaths() {
    let r = Cleaner.adminDelete([Item(path: "/etc/hosts", size: 1)])
    #expect(r.done.isEmpty && r.failures.count == 1)
    #expect(FileManager.default.fileExists(atPath: "/etc/hosts"))
}

@Test func systemJunkSkipsProtected() throws {
    let h = try makeHome()
    try write(h + "/Library/Caches/com.foo/a", bytes: 5000)
    try write(h + "/Library/Caches/com.apple.bar/a", bytes: 5000)
    try write(h + "/Library/Caches/com.running/a", bytes: 5000)
    try write(h + "/Library/Logs/old.log", bytes: 5000)
    let names = Scan.systemJunk(home: h, running: ["com.running"], minSize: 1).map(\.name).sorted()
    #expect(names == ["com.foo", "old.log"])
}

@Test func cleanerOnlyMovesAllowedPaths() throws {
    let h = try makeHome()
    let ok = h + "/Library/Caches/com.foo", bad = h + "/Documents"
    try write(ok + "/a")
    try write(bad + "/keep.txt")
    let r = Cleaner.trash([Item(path: ok, size: 10), Item(path: bad, size: 10)], home: h) {
        try FileManager.default.removeItem(at: $0)
    }
    #expect(r.done == [ok] && r.freed == 10 && r.failures.count == 1)
    #expect(!FileManager.default.fileExists(atPath: ok))
    #expect(FileManager.default.fileExists(atPath: bad + "/keep.txt"))
}

@Test func autoCleanRemovesCachesOnly() throws {
    let h = try makeHome()
    try write(h + "/Library/Caches/com.foo/a", bytes: 2_000_000)
    try write(h + "/.npm/_cacache/b", bytes: 2_000_000)
    try write(h + "/Documents/keep.txt", bytes: 2_000_000)
    let r = AutoClean.run(home: h, running: [])
    #expect(r.done.count == 2 && r.failures.isEmpty)
    #expect(FileManager.default.fileExists(atPath: h + "/Documents/keep.txt"))
}

@Test func staleBuildDirsRespectsAge() throws {
    let h = try makeHome()
    let old = Date().addingTimeInterval(-90 * 86_400)
    try write(h + "/old/node_modules/x/index.js")
    try write(h + "/old/package.json", modified: old)
    try write(h + "/fresh/node_modules/x/index.js")
    try write(h + "/fresh/package.json")
    #expect(Scan.staleBuildDirs(root: h).map(\.path) == [h + "/old/node_modules"])
}

@Test func largeOldThresholds() throws {
    let h = try makeHome()
    try write(h + "/big.bin", bytes: 300)
    try write(h + "/small.bin", bytes: 50)
    let found = Scan.largeOld([h], large: 200, oldMin: 1000, days: 180)
    #expect(found.map(\.name) == ["big.bin"] && found[0].note == "large file")
    let later = Date().addingTimeInterval(400 * 86_400)
    #expect(Scan.largeOld([h], large: 1000, oldMin: 40, days: 180, now: later).count == 2)
}

@Test func duplicatesGroupIdenticalContent() throws {
    let h = try makeHome()
    try write(h + "/a.bin", bytes: 100, fill: 1)
    try write(h + "/sub/b.bin", bytes: 100, fill: 1)
    try write(h + "/c.bin", bytes: 100, fill: 2)   // same size, different content
    let found = Scan.duplicates([h], minSize: 1)
    #expect(Set(found.map(\.name)) == ["a.bin", "b.bin"])
    #expect(Set(found.map(\.group)).count == 1)
    #expect(found.filter { $0.note == "duplicate" }.count == 1)
}

@Test func leftoversMatchExactly() throws {
    let h = try makeHome()
    try write(h + "/Library/Caches/com.foo.app/a")
    try write(h + "/Library/Caches/com.foo.app2/a")
    try write(h + "/Library/Preferences/com.foo.app.plist")
    let app = AppInfo(path: "/Applications/Foo.app", bundleID: "com.foo.app", size: 0)
    #expect(Apps.leftovers(app, home: h).map(\.name).sorted() == ["com.foo.app", "com.foo.app.plist"])
}

@Test func psParsing() {
    let procs = Memory.parsePS("  123  2048 /Applications/My App.app/Contents/MacOS/My App\n 9 10 /bin/zsh\nbad line")
    #expect(procs.count == 2)
    #expect(procs[0].pid == 123 && procs[0].rss == 2048 * 1024 && procs[0].name == "My App")
    #expect(Memory.usage().total > 0 && Memory.usage().used > 0)
}

@Test func schedulePlist() {
    let weekly = Schedule.plist(binary: "/x/Sweep", config: .init(on: true, weekly: true, weekday: 3, hour: 9, minute: 30))
    #expect(weekly["ProgramArguments"] as? [String] == ["/x/Sweep", "--auto-clean"])
    #expect(weekly["StartCalendarInterval"] as? [String: Int] == ["Weekday": 3, "Hour": 9, "Minute": 30])
    #expect((Schedule.plist(binary: "/x", config: .init(.daily))["StartCalendarInterval"] as? [String: Int])?["Weekday"] == nil)
    #expect(Schedule.Config(.weekly).weekday == 0)   // preset: Sunday 12:00
}

@Test func scheduleRoundTripAndNextRun() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("s.plist").path
    let c = Schedule.Config(on: true, weekly: true, weekday: 5, hour: 18, minute: 45)
    #expect((Schedule.plist(binary: "/x", config: c) as NSDictionary).write(toFile: path, atomically: true))
    #expect(Schedule.current(path: path) == c)
    #expect(Schedule.current(path: dir.appendingPathComponent("missing").path).on == false)

    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let tue = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 20))!   // Tuesday
    let next = try #require(Schedule.nextRun(c, after: tue, calendar: cal))
    #expect(cal.dateComponents([.weekday, .hour, .minute, .day], from: next) == DateComponents(day: 20, hour: 18, minute: 45, weekday: 6))  // Friday
    #expect(Schedule.nextRun(.init(), after: tue, calendar: cal) == nil)
    #expect(Schedule.Config(on: false, weekly: false, hour: 3).same(as: Schedule.Config()))   // off == off
    #expect(!Schedule.Config(on: true, weekly: true, weekday: 1).same(as: .init(on: true, weekly: true, weekday: 2)))
}

@Test func dockerPruneNeverTouchesContainersOrVolumes() {
    let words = Set(Docker.pruneCommands.joined())
    #expect(words.isDisjoint(with: ["system", "container", "volume", "--volumes"]))
    #expect(Docker.pruneCommands.contains(["builder", "prune", "-f"]))
}

@Test func finderTrashScriptQuoting() {
    #expect(Cleaner.finderTrashScript("/Applications/My \"App\".app")
            == #"tell application "Finder" to delete (POSIX file "/Applications/My \"App\".app" as alias)"#)
}

@Test func systemComponentsMatchVendor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    for f in ["com.teamviewer.Helper.plist", "com.other.thing.plist"] {
        FileManager.default.createFile(atPath: root + "/" + f, contents: Data())
    }
    let app = AppInfo(path: "/Applications/TeamViewer.app", bundleID: "com.teamviewer.TeamViewer", size: 1)
    #expect(Apps.systemComponents(app, roots: [root]) == [root + "/com.teamviewer.Helper.plist"])
}
