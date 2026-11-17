import AppKit
import Combine
import SwiftUI
import SweepCore

// Note: no `.fixedSize` on text inside these stretchy layouts. It once made SwiftUI draw a blank window.

extension Color {
    /// Mint-teal, matching the app icon.
    static let brand = Color(red: 0.12, green: 0.70, blue: 0.64)
}

extension Section {
    var color: Color {
        switch self {
        case .overview: .brand
        case .system: .blue
        case .dev: .orange
        case .large: .purple
        case .dupes: .pink
        case .admin: .red
        case .apps: .indigo
        case .memory: .green
        case .docker: .cyan
        case .schedule: .teal
        }
    }
}

struct SweepApp: App {
    @StateObject private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("Sweep") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
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

// MARK: Shared pieces

/// Coloured rounded tile with a white symbol, like System Settings.
struct IconTile: View {
    let section: Section
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: section.icon)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct Header<Trailing: View>: View {
    let section: Section
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            IconTile(section: section)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.rawValue).font(.title2.weight(.bold))
                Text(section.blurb).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing.layoutPriority(2)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}

// MARK: Window

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 240, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.section ?? .overview {
                    case .overview: OverviewView()
                    case .apps: AppsView()
                    case .memory: MemoryView()
                    case .docker: DockerView()
                    case .schedule: ScheduleView()
                    case let s: ItemsView(section: s).id(s)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
        }
        .tint(.brand)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .alert("Sweep",
               isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert ?? "")
        }
        .confirmationDialog("Empty the Trash?", isPresented: $model.confirmEmpty) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("Everything in the Trash is deleted permanently. This cannot be undone.")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: Model

    func row(_ s: Section) -> some View {
        Label {
            Text(s.rawValue)
        } icon: {
            Image(systemName: s.icon).foregroundStyle(s.color)
        }
        .badge(model.total(s).flatMap { $0 > 0 ? Text(FS.format($0)) : nil })
        .tag(s)
    }

    var body: some View {
        List(selection: $model.section) {
            row(.overview)
            SwiftUI.Section("Clean") { ForEach(Model.cleanable) { row($0) } }
            SwiftUI.Section("Manage") { ForEach([Section.apps, .memory, .docker]) { row($0) } }
            SwiftUI.Section("Automate") { row(.schedule) }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            ProgressView(value: Double(model.diskTotal - model.freeSpace), total: Double(max(model.diskTotal, 1)))
                .frame(width: 90)
            Text("\(FS.format(model.freeSpace)) free").monospacedDigit()
            if !model.message.isEmpty {
                Divider().frame(height: 14)
                Text(model.message).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button { model.confirmEmpty = true } label: { Label("Empty Trash…", systemImage: "trash") }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: Overview

struct OverviewView: View {
    @EnvironmentObject var model: Model

    var used: Int64 { model.diskTotal - model.freeSpace }
    var fraction: Double { Double(used) / Double(max(model.diskTotal, 1)) }
    var scanning: Bool { Model.cleanable.contains { model.busy.contains($0) } }
    var found: Int64 { Model.cleanable.compactMap { model.total($0) }.reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Card {
                    HStack(spacing: 28) {
                        ZStack {
                            Circle().stroke(.quaternary, lineWidth: 16)
                            Circle().trim(from: 0, to: fraction)
                                .stroke(LinearGradient(colors: [.brand, .blue], startPoint: .top, endPoint: .bottom),
                                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text(FS.format(model.freeSpace)).font(.title2.weight(.bold)).monospacedDigit()
                                Text("free").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 150, height: 150)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Macintosh HD").font(.title.weight(.bold))
                            Text("\(FS.format(used)) used of \(FS.format(model.diskTotal))").foregroundStyle(.secondary)
                            if found > 0 {
                                Label("\(FS.format(found)) can be cleaned", systemImage: "sparkles")
                                    .font(.headline).foregroundStyle(Color.brand)
                            }
                            Button { model.scanAll() } label: {
                                Label(scanning ? "Scanning…" : "Smart Scan", systemImage: "magnifyingglass")
                                    .frame(minWidth: 150)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(scanning)
                            .padding(.top, 6)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Text("Clean").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                    ForEach(Model.cleanable) { s in
                        Button { model.section = s } label: { CategoryCard(section: s) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct CategoryCard: View {
    let section: Section
    @EnvironmentObject var model: Model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(section: section, size: 34)
                    Spacer()
                    if model.busy.contains(section) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                Text(section.rawValue).font(.headline)
                if let total = model.total(section) {
                    Text(total == 0 ? "All clean" : FS.format(total))
                        .font(.title2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(total == 0 ? Color.green : Color.primary)
                } else {
                    Text("Not scanned").font(.title2.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
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
    var biggest: Int64 { max(items.first?.size ?? 1, 1) }

    func toggle(_ item: Item) {
        var s = picked
        if s.contains(item.path) { s.remove(item.path) } else { s.insert(item.path) }
        model.selected[section] = s
    }

    func binding(_ item: Item) -> Binding<Bool> {
        Binding(get: { picked.contains(item.path) }, set: { _ in toggle(item) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(section: section) {
                Button { model.scan(section) } label: {
                    Label(model.items[section] == nil ? "Scan" : "Rescan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("r").disabled(busy)
            }

            let blocked = model.blocked(section)
            if !blocked.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("No access to \(blocked.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")). Results may be incomplete.")
                    Spacer()
                    Button("Open Full Disk Access") { openFullDiskAccess() }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if busy && items.isEmpty {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items[section] == nil {
                ContentUnavailableView {
                    Label("Not scanned yet", systemImage: section.icon)
                } description: {
                    Text("Press Scan to look for files you can remove.")
                } actions: {
                    Button("Scan") { model.scan(section) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("All clean", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } description: {
                    Text("Nothing to remove here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    HStack(spacing: 12) {
                        Toggle("", isOn: binding(item)).toggleStyle(.checkbox).labelsHidden()
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                            .resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                if !item.note.isEmpty {
                                    Text(item.note).font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(section.color.opacity(0.15), in: Capsule())
                                        .foregroundStyle(section.color)
                                }
                            }
                            Text(item.path.replacingOccurrences(of: FS.home, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(FS.format(item.size)).font(.callout.weight(.semibold)).monospacedDigit()
                            ProgressView(value: Double(item.size), total: Double(biggest))
                                .tint(section.color).frame(width: 80)
                        }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(item) }
                    .contextMenu { Button("Reveal in Finder") { reveal(item.path) } }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    if section != .dupes {   // selecting every copy would leave no original
                        Button("Select all") { model.selected[section] = Set(items.map(\.path)) }
                    }
                    if section == .dupes {
                        Button("Select duplicates") {
                            model.selected[section] = Set(items.filter { $0.note == "duplicate" }.map(\.path))
                        }
                    }
                    Button("Select none") { model.selected[section] = [] }.disabled(picked.isEmpty)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(picked.count) of \(items.count) selected").font(.caption).foregroundStyle(.secondary)
                        Text(FS.format(pickedSize)).font(.title3.weight(.bold)).monospacedDigit()
                    }
                    if section == .admin {
                        Button { model.confirmAdmin = true } label: { Label("Delete…", systemImage: "trash") }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                            .disabled(picked.isEmpty || busy)
                    } else {
                        Button { model.clean(section) } label: { Label("Move to Trash", systemImage: "trash") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.delete, modifiers: .command).disabled(picked.isEmpty || busy)   // ⌘⌫, like Finder
                    }
                }
                .padding(12)
                .background(.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 14) {
            Header(section: .apps) { EmptyView() }
            HSplitView {
                Group {
                    if let apps = model.apps {
                        List(apps, selection: Binding(get: { model.chosenApp?.id }, set: { model.choose($0) })) { app in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 26, height: 26)
                                Text(app.name)
                                Spacer()
                                Text(FS.format(app.size)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(app.id)
                        }
                        .listStyle(.inset)
                    } else {
                        ProgressView("Listing apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 280)

                Group {
                    if let app = model.chosenApp {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.title2.weight(.bold))
                                    Text(app.bundleID).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    LabeledContent("App", value: FS.format(app.size))
                                    LabeledContent("Leftover files", value: model.loadingLeftovers ? "Looking…" : "\(model.leftovers.count)")
                                    ForEach(model.leftovers) { item in
                                        HStack {
                                            Text(item.path.replacingOccurrences(of: FS.home, with: "~"))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(FS.format(item.size)).font(.caption).monospacedDigit()
                                        }
                                    }
                                }
                            }
                            if !model.systemParts.isEmpty {
                                Card {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("Also installed background services", systemImage: "exclamationmark.triangle.fill")
                                            .font(.headline).foregroundStyle(.orange)
                                        Text("These stay after uninstalling. For a clean removal, use the app's own uninstaller, usually in its menu or settings.")
                                            .font(.callout).foregroundStyle(.secondary).layoutPriority(1)
                                        ForEach(model.systemParts, id: \.self) {
                                            Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                }
                            }
                            Spacer()
                            if running {
                                Label("Quit \(app.name) before uninstalling.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Button { model.confirmUninstall = true } label: {
                                Label(model.uninstalling ? "Uninstalling…" : "Uninstall · \(FS.format(total))", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                            .disabled(running || model.uninstalling || model.loadingLeftovers)
                        }
                    } else {
                        ContentUnavailableView("Choose an app", systemImage: "xmark.app",
                                               description: Text("Its leftover files are found automatically."))
                    }
                }
                .padding()
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
        .navigationTitle("Uninstall apps")
        .onAppear { model.loadApps() }
        .confirmationDialog("Uninstall \(model.chosenApp?.name ?? "")?", isPresented: $model.confirmUninstall) {
            Button("Move to Trash", role: .destructive) { model.uninstall() }
        } message: {
            Text("The app and \(model.leftovers.count) leftover items go to the Trash. You can put them back from there. If the app was installed by a package, macOS asks for your password.")
        }
    }
}

// MARK: Memory

struct MemoryView: View {
    @EnvironmentObject var model: Model
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var fraction: Double { Double(model.memUsed) / Double(max(model.memTotal, 1)) }
    var barColor: Color { fraction > 0.85 ? .red : fraction > 0.7 ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(section: .memory) {
                Button { model.purge() } label: { Label("Purge", systemImage: "wind") }.controlSize(.large)
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(FS.format(model.memUsed)).font(.title.weight(.bold)).monospacedDigit()
                        Text("of \(FS.format(model.memTotal)) in use").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(fraction * 100))%").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(barColor)
                    }
                    ProgressView(value: fraction).tint(barColor)
                }
            }
            Table(model.procs) {
                TableColumn("Process", value: \.name)
                TableColumn("Memory") { Text(FS.format($0.rss)).monospacedDigit() }.width(90)
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit().foregroundStyle(.secondary) }.width(60)
                TableColumn("") { p in Button("Quit") { model.toQuit = p }.buttonStyle(.link) }.width(50)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
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
        VStack(alignment: .leading, spacing: 14) {
            Header(section: .docker) {
                HStack {
                    if model.dockerBusy { ProgressView().controlSize(.small) }
                    Button { model.loadDocker() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .controlSize(.large).disabled(model.dockerBusy)
                    Button { model.confirmPrune = true } label: { Label("Prune…", systemImage: "trash") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.dockerBusy || Docker.binary == nil)
                }
            }
            Card {
                ScrollView {
                    Text(model.dockerOutput).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle("Docker")
        .onAppear { model.loadDocker() }
        .confirmationDialog("Prune Docker?", isPresented: $model.confirmPrune) {
            Button("Prune", role: .destructive) { model.pruneDocker() }
        } message: {
            Text("Build cache and images no container uses are deleted permanently. Docker downloads images again when a project needs them. Containers and volumes are kept.")
        }
    }
}

// MARK: Schedule

struct ScheduleView: View {
    @EnvironmentObject var model: Model
    let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]

    var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: model.scheduleDraft.hour, minute: model.scheduleDraft.minute)) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                model.scheduleDraft.hour = c.hour ?? 12
                model.scheduleDraft.minute = c.minute ?? 0
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(section: .schedule) { EmptyView() }

            // What is actually installed right now.
            Card {
                if let next = Schedule.nextRun(model.scheduleSaved) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic cleaning is on").font(.headline)
                            Text("Next clean \(next.formatted(.relative(presentation: .named))), \(next.formatted(date: .complete, time: .shortened)).")
                                .foregroundStyle(.secondary)
                            if let last = Schedule.lastRun() {
                                Text("Last run: " + last).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic cleaning is off").font(.headline)
                            Text("Nothing is cleaned unless you do it yourself.").foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }
                }
            }

            // Settings you can edit freely; nothing changes until Save.
            Form {
                Toggle("Clean automatically", isOn: $model.scheduleDraft.on).toggleStyle(.switch)
                if model.scheduleDraft.on {
                    Picker("Repeat", selection: $model.scheduleDraft.weekly) {
                        Text("Every day").tag(false)
                        Text("Every week").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if model.scheduleDraft.weekly {
                        Picker("Day", selection: $model.scheduleDraft.weekday) {
                            ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                        }
                    }
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                }
                SwiftUI.Section {
                    Label("Only app caches, logs and package-manager caches (npm, yarn, pnpm, gradle, cargo, Xcode), deleted permanently so the space comes back right away.",
                          systemImage: "checkmark.shield")
                    Label("Large files, duplicates, projects and Docker are never touched automatically.", systemImage: "hand.raised")
                    Label("If the Mac is asleep at that time, it runs when it wakes.", systemImage: "moon.zzz")
                    if !binary.hasPrefix("/Applications/") {
                        Label("Move Sweep.app to Applications first, so the schedule keeps working.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)   // grouped forms add their own side margins

            if model.scheduleChanged {
                HStack(spacing: 10) {
                    Label("Unsaved changes", systemImage: "pencil.circle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Revert") { model.scheduleDraft = model.scheduleSaved }.controlSize(.large)
                    Button(model.savingSchedule ? "Saving…" : "Save") { model.saveSchedule(binary: binary) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("s").disabled(model.savingSchedule)
                }
                .padding(12)
                .background(.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Schedule")
    }
}
