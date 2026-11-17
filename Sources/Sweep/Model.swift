import AppKit
import SwiftUI
import SweepCore

enum Section: String, CaseIterable, Identifiable {
    case system = "System junk", dev = "Developer junk", large = "Large & old files", dupes = "Duplicates"
    case admin = "System-wide caches", apps = "Uninstall apps", memory = "Memory", docker = "Docker", schedule = "Schedule"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: "trash"
        case .dev: "hammer"
        case .large: "doc.badge.clock"
        case .dupes: "doc.on.doc"
        case .admin: "lock.shield"
        case .apps: "xmark.app"
        case .memory: "memorychip"
        case .docker: "shippingbox"
        case .schedule: "calendar.badge.clock"
        }
    }

    var blurb: String {
        switch self {
        case .system: "App caches and logs in your Library. Apps rebuild them as needed. Caches of running apps are skipped."
        case .dev: "Package manager caches, Xcode build data, and node_modules/.next in projects untouched for \(Scan.staleProjectDays)+ days."
        case .large: "Files in Downloads, Desktop and Documents over 100 MB, or over 10 MB and not opened in \(Scan.oldDays) days. Review each one."
        case .dupes: "Files over 1 MB with identical contents. The oldest copy is marked original."
        case .admin: "Caches and logs shared by all users in /Library. Deleted permanently; macOS asks for your password."
        default: ""
        }
    }

    /// Folders the section reads, used to warn when macOS blocks access.
    var folders: [String] {
        let h = FS.home
        switch self {
        case .system: return [h + "/Library/Caches", h + "/Library/Logs"]
        case .large, .dupes: return [h + "/Downloads", h + "/Desktop", h + "/Documents"]
        case .admin: return ["/Library/Caches", "/Library/Logs"]
        default: return []
        }
    }
}

// All view state lives here: the command line tools ship without the SwiftUI macro
// plugin that `@State` needs on the macOS 26 SDK, while `@Published` works everywhere.
@MainActor
final class Model: ObservableObject {
    @Published var section: Section? = .system
    @Published var items: [Section: [Item]] = [:]
    @Published var selected: [Section: Set<String>] = [:]
    @Published var busy: Set<Section> = []
    @Published var message = ""
    @Published var freeSpace: Int64 = 0
    @Published var confirmEmpty = false
    @Published var confirmAdmin = false

    @Published var apps: [AppInfo]? = nil
    @Published var chosenApp: AppInfo? = nil
    @Published var leftovers: [Item] = []
    @Published var confirmUninstall = false

    @Published var memUsed: Int64 = 0
    @Published var memTotal: Int64 = 1
    @Published var procs: [Proc] = []
    @Published var toQuit: Proc? = nil

    @Published var dockerOutput = "Loading…"
    @Published var dockerBusy = false
    @Published var confirmPrune = false

    @Published var scheduleMode = Schedule.current()

    init() { refreshFreeSpace() }

    // MARK: Apps

    func loadApps() {
        guard apps == nil else { return }
        Task.detached {
            let list = Apps.list()
            await MainActor.run { self.apps = list }
        }
    }

    func choose(_ id: String?) {
        chosenApp = apps?.first { $0.id == id }
        leftovers = chosenApp.map { Apps.leftovers($0) } ?? []
    }

    func uninstall() {
        guard let app = chosenApp else { return }
        let r = Cleaner.trash([Item(path: app.path, size: app.size)] + leftovers)
        report(r, trashed: true)
        if r.done.contains(app.path) {
            apps?.removeAll { $0.id == app.id }
            choose(nil)
        }
    }

    // MARK: Memory

    func refreshMemory() {
        (memUsed, memTotal) = Memory.usage()
        procs = Memory.top()
    }

    func quitChosenProcess() {
        guard let p = toQuit else { return }
        if let app = NSRunningApplication(processIdentifier: p.pid) { app.terminate() } else { Memory.quit(p.pid) }
        toQuit = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshMemory() }
    }

    func purge() {
        Task.detached {
            let msg = Memory.purge()
            await MainActor.run { self.message = msg }
        }
    }

    // MARK: Docker

    func loadDocker() {
        dockerBusy = true
        Task.detached {
            let text = Docker.usage()
            await MainActor.run { self.dockerOutput = text; self.dockerBusy = false }
        }
    }

    func pruneDocker() {
        dockerBusy = true
        Task.detached {
            let text = Docker.prune()
            await MainActor.run {
                self.message = text.split(separator: "\n").last.map(String.init) ?? "Docker pruned."
                self.loadDocker()
            }
        }
    }

    func refreshFreeSpace() {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeSpace = v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func blocked(_ s: Section) -> [String] { s.folders.filter { !FS.readable($0) } }

    func scan(_ s: Section) {
        busy.insert(s)
        let running = runningIDs()
        Task.detached {
            let found = Model.compute(s, running: running)
            await MainActor.run {
                self.items[s] = found
                self.selected[s] = []
                self.busy.remove(s)
            }
        }
    }

    nonisolated static func compute(_ s: Section, running: Set<String>) -> [Item] {
        switch s {
        case .system: return Scan.systemJunk(running: running)
        case .dev: return Scan.devJunk(projects: FS.home + "/Projects")
        case .large: return Scan.largeOld(s.folders)
        case .dupes: return Scan.duplicates(s.folders)
        case .admin: return Scan.adminJunk()
        default: return []
        }
    }

    func clean(_ s: Section) {
        let chosen = (items[s] ?? []).filter { selected[s]?.contains($0.path) == true }
        guard !chosen.isEmpty else { return }
        busy.insert(s)
        Task.detached {
            let r = s == .admin ? Cleaner.adminDelete(chosen) : Cleaner.trash(chosen)
            await MainActor.run {
                let done = Set(r.done)
                self.items[s]?.removeAll { done.contains($0.path) }
                self.selected[s] = []
                self.busy.remove(s)
                self.report(r, trashed: s != .admin)
            }
        }
    }

    func report(_ r: CleanResult, trashed: Bool) {
        var text = trashed
            ? "Moved \(r.done.count) items (\(FS.format(r.freed))) to the Trash. Empty the Trash to free the space."
            : "Removed \(r.done.count) items, freed \(FS.format(r.freed))."
        if !r.failures.isEmpty { text += " \(r.failures.count) failed: " + r.failures.prefix(2).joined(separator: "; ") }
        message = text
        refreshFreeSpace()
    }

    func emptyTrash() {
        let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
        message = r.status == 0 ? "Trash emptied." : "Could not empty the Trash. \(r.out)"
        refreshFreeSpace()
    }
}

extension Model {
    /// `Sweep --snapshot DIR`: visits a few sections, scanning where needed, saves a PNG of the
    /// window for each, then quits. Used to check the UI without Screen Recording permission.
    func snapshot(to dir: String) async {
        try? await Task.sleep(for: .seconds(2))   // let the window finish its first layout
        for (i, s) in [Section.system, .dev, .large, .apps, .memory, .docker, .schedule].enumerated() {
            section = s
            if [.system, .dev, .large].contains(s) {
                scan(s)
                while busy.contains(s) { try? await Task.sleep(for: .milliseconds(200)) }
                if let first = items[s]?.first { selected[s] = [first.path] }
            }
            try? await Task.sleep(for: .seconds(s == .apps || s == .docker ? 3 : 1.5))
            if s == .apps, let first = apps?.first { choose(first.id); try? await Task.sleep(for: .seconds(1)) }
            // Render the layer tree: cacheDisplay skips SwiftUI's layer-backed text and controls.
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView?.superview, let layer = view.layer,
                  let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { continue }
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            ctx.scaleBy(x: 2, y: 2)
            layer.render(in: ctx)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(i)-\(s.icon).png"))
        }
        NSApp.terminate(nil)
    }
}

func openFullDiskAccess() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
