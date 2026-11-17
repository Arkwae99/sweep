import AppKit
import SweepCore

// Headless modes, so launchd (and you) can run Sweep without the window.
let args = CommandLine.arguments

/// Names a running app's cache folder might use: bundle ID, app name, and distinctive
/// bundle-ID parts (Chrome is com.google.Chrome but caches in ~/Library/Caches/Google).
func runningIDs() -> Set<String> {
    let generic: Set<String> = ["com", "org", "net", "io", "app", "apple", "inc", "helper", "mac", "macos"]
    var names = Set<String>()
    for app in NSWorkspace.shared.runningApplications {
        if let id = app.bundleIdentifier?.lowercased() {
            names.insert(id)
            id.split(separator: ".").map(String.init).filter { $0.count >= 4 && !generic.contains($0) }
                .forEach { names.insert($0) }
        }
        if let name = app.localizedName?.lowercased() { names.insert(name) }
    }
    return names
}

if args.contains("--auto-clean") {
    let r = AutoClean.run(running: runningIDs())
    print("\(Date()) Sweep auto-clean freed \(FS.format(r.freed)), \(r.done.count) items, \(r.failures.count) failures")
    r.failures.forEach { print("  failed: \($0)") }
    exit(0)
}

// `Sweep --trash PATH...`: same safety gate and Trash move as the window's "Move to Trash".
if let i = args.firstIndex(of: "--trash") {
    let items = args[(i + 1)...].map { Item(path: $0, size: FS.size($0)) }
    let r = Cleaner.trash(items)
    print("Moved \(r.done.count) items (\(FS.format(r.freed))) to the Trash.")
    r.failures.forEach { print("  failed: \($0)") }
    exit(r.failures.isEmpty ? 0 : 1)
}

if args.contains("--scan") {
    let projects = FS.home + "/Projects"
    let report: [(String, [Item])] = [
        ("System junk", Scan.systemJunk(running: runningIDs())),
        ("Developer junk", Scan.devJunk(projects: projects)),
    ]
    for (title, items) in report {
        print("\(title): \(FS.format(items.reduce(0) { $0 + $1.size })) in \(items.count) items")
        items.prefix(5).forEach { print("  \(FS.format($0.size))\t\($0.path)") }
    }
    exit(0)
}

SweepApp.main()
