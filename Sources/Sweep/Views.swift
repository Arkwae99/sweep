import AppKit
import Combine
import SwiftUI
import SweepCore

struct SweepApp: App {
    @StateObject private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("Sweep") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
                        Task { await model.snapshot(to: args[i + 1]) }
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $model.section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.section ?? .system {
                    case .apps: AppsView()
                    case .memory: MemoryView()
                    case .docker: DockerView()
                    case .schedule: ScheduleView()
                    case let s: ItemsView(section: s).id(s)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text("Free space: \(FS.format(model.freeSpace))").monospacedDigit()
                    Text(model.message).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Empty Trash…") { model.confirmEmpty = true }
                }
                .padding(10)
            }
        }
        .confirmationDialog("Empty the Trash?", isPresented: $model.confirmEmpty) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("Everything in the Trash is deleted permanently. This cannot be undone.")
        }
    }
}

// MARK: Scan-and-review sections

struct ItemsView: View {
    let section: Section
    @EnvironmentObject var model: Model

    var items: [Item] { model.items[section] ?? [] }
    var picked: Set<String> { model.selected[section] ?? [] }
    var pickedSize: Int64 { items.filter { picked.contains($0.path) }.reduce(0) { $0 + $1.size } }
    var busy: Bool { model.busy.contains(section) }

    func binding(_ item: Item) -> Binding<Bool> {
        Binding(
            get: { picked.contains(item.path) },
            set: { on in
                var s = picked
                if on { s.insert(item.path) } else { s.remove(item.path) }
                model.selected[section] = s
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(section.blurb).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(model.items[section] == nil ? "Scan" : "Rescan") { model.scan(section) }
                    .keyboardShortcut("r").disabled(busy)
            }
            let blocked = model.blocked(section)
            if !blocked.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("No access to \(blocked.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")). Results may be incomplete.")
                    Button("Open Full Disk Access") { openFullDiskAccess() }.buttonStyle(.link)
                }.font(.callout)
            }
            if model.items[section] == nil {
                ContentUnavailableView("Not scanned yet", systemImage: section.icon, description: Text("Press Scan to look for files to remove."))
            } else if items.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: "checkmark.circle")
            } else {
                List(items) { item in
                    Toggle(isOn: binding(item)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text([item.group.isEmpty ? nil : "group \(item.group)", item.note.isEmpty ? nil : item.note, item.path]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(FS.format(item.size)).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .contextMenu { Button("Reveal in Finder") { reveal(item.path) } }
                }
                HStack {
                    Button("Select all") { model.selected[section] = Set(items.map(\.path)) }
                    if section == .dupes {
                        Button("Select duplicates") {
                            model.selected[section] = Set(items.filter { $0.note == "duplicate" }.map(\.path))
                        }
                    }
                    Button("Select none") { model.selected[section] = [] }
                    Spacer()
                    Text("\(picked.count) selected · \(FS.format(pickedSize))").monospacedDigit()
                    if section == .admin {
                        Button("Delete…") { model.confirmAdmin = true }.disabled(picked.isEmpty || busy)
                    } else {
                        Button("Move to Trash") { model.clean(section) }
                            .keyboardShortcut(.delete).disabled(picked.isEmpty || busy)
                    }
                }
            }
        }
        .padding()
        .navigationTitle(section.rawValue)
        .confirmationDialog("Delete \(picked.count) system items?", isPresented: $model.confirmAdmin) {
            Button("Delete permanently", role: .destructive) { model.clean(section) }
        } message: {
            Text("\(FS.format(pickedSize)) will be removed permanently. macOS will ask for your password.")
        }
    }
}

// MARK: App uninstaller

struct AppsView: View {
    @EnvironmentObject var model: Model

    var running: Bool {
        guard let c = model.chosenApp else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == c.bundleID }
    }
    var total: Int64 { (model.chosenApp?.size ?? 0) + model.leftovers.reduce(0) { $0 + $1.size } }

    var body: some View {
        HSplitView {
            Group {
                if let apps = model.apps {
                    List(apps, selection: Binding(get: { model.chosenApp?.id }, set: { model.choose($0) })) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                            Text(app.name)
                            Spacer()
                            Text(FS.format(app.size)).monospacedDigit().foregroundStyle(.secondary)
                        }.tag(app.id)
                    }
                } else {
                    ProgressView("Listing apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 280)

            VStack(alignment: .leading, spacing: 10) {
                if let app = model.chosenApp {
                    Text(app.name).font(.title2)
                    Text(app.bundleID).foregroundStyle(.secondary)
                    Text("App: \(FS.format(app.size))")
                    Text(model.leftovers.isEmpty ? "No leftover files found." : "Leftover files:").padding(.top, 6)
                    ForEach(model.leftovers) { item in
                        HStack {
                            Text(item.path.replacingOccurrences(of: FS.home, with: "~")).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(FS.format(item.size)).font(.caption).monospacedDigit()
                        }
                    }
                    Spacer()
                    if running { Text("Quit \(app.name) before uninstalling.").foregroundStyle(.orange) }
                    Button("Uninstall (move \(FS.format(total)) to Trash)…") { model.confirmUninstall = true }.disabled(running)
                } else {
                    ContentUnavailableView("Choose an app", systemImage: "xmark.app")
                }
            }
            .padding()
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Uninstall apps")
        .onAppear { model.loadApps() }
        .confirmationDialog("Uninstall \(model.chosenApp?.name ?? "")?", isPresented: $model.confirmUninstall) {
            Button("Move to Trash", role: .destructive) { model.uninstall() }
        } message: {
            Text("The app and \(model.leftovers.count) leftover items go to the Trash. You can put them back from there.")
        }
    }
}

// MARK: Memory

struct MemoryView: View {
    @EnvironmentObject var model: Model
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var fraction: Double { Double(model.memUsed) / Double(max(model.memTotal, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Gauge(value: fraction) {
                Text("Memory in use")
            } currentValueLabel: {
                Text("\(FS.format(model.memUsed)) of \(FS.format(model.memTotal))").monospacedDigit()
            }
            .tint(fraction > 0.85 ? .red : .accentColor)
            HStack {
                Text("macOS uses spare memory for caching on purpose. Quitting heavy apps frees real memory; purging only clears the disk cache.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Purge inactive memory") { model.purge() }
            }
            Table(model.procs) {
                TableColumn("Process", value: \.name)
                TableColumn("Memory") { Text(FS.format($0.rss)).monospacedDigit() }.width(90)
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }.width(60)
                TableColumn("") { p in Button("Quit") { model.toQuit = p } }.width(60)
            }
        }
        .padding()
        .navigationTitle("Memory")
        .onAppear { model.refreshMemory() }
        .onReceive(timer) { _ in model.refreshMemory() }
        .confirmationDialog("Quit \(model.toQuit?.name ?? "")?",
                            isPresented: Binding(get: { model.toQuit != nil }, set: { if !$0 { model.toQuit = nil } })) {
            Button("Quit", role: .destructive) { model.quitChosenProcess() }
        } message: {
            Text("Apps get a chance to save. Background processes are asked to stop.")
        }
    }
}

// MARK: Docker

struct DockerView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Removes stopped containers, unused networks, dangling images and build cache. Volumes and images in use are kept.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.dockerOutput).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                if model.dockerBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { model.loadDocker() }.disabled(model.dockerBusy)
                Button("Prune…") { model.confirmPrune = true }.disabled(model.dockerBusy || Docker.binary == nil)
            }
        }
        .padding()
        .navigationTitle("Docker")
        .onAppear { model.loadDocker() }
        .confirmationDialog("Prune Docker?", isPresented: $model.confirmPrune) {
            Button("Prune", role: .destructive) { model.pruneDocker() }
        } message: {
            Text("This deletes permanently and cannot be undone.")
        }
    }
}

// MARK: Schedule

struct ScheduleView: View {
    @EnvironmentObject var model: Model
    let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]

    var body: some View {
        Form {
            Picker("Clean automatically", selection: $model.scheduleMode) {
                ForEach(Schedule.Mode.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            .pickerStyle(.segmented)
            Text("Runs at 12:00 (weekly: Sundays). Only app caches, logs and developer tool caches are removed, permanently, so the space is freed right away. Large files, duplicates and projects are never touched automatically.")
                .foregroundStyle(.secondary)
            LabeledContent("Runs", value: binary).font(.caption)
            if !binary.hasPrefix("/Applications/") {
                Text("Move Sweep.app to Applications first, so the schedule keeps working if this folder changes.")
                    .foregroundStyle(.orange).font(.callout)
            }
            Button("Apply") { model.message = Schedule.set(model.scheduleMode, binary: binary) }
        }
        .formStyle(.grouped)
        .navigationTitle("Schedule")
    }
}
