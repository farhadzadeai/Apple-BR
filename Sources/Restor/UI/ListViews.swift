import SwiftUI
import AppKit
import AVFoundation

private func load<T: Sendable>(_ backup: Backup, _ work: @escaping @Sendable (Backup) -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work(backup) }.value
}

struct CallsView: View {
    let backup: Backup
    @State private var calls: [CallRecord]?
    @State private var search = ""
    @State private var missedOnly = false
    @State private var selection: Int64?

    private var filtered: [CallRecord] {
        (calls ?? []).filter { call in
            (!missedOnly || call.kind == .missed)
                && (search.isEmpty || call.name.localizedCaseInsensitiveContains(search) || call.address.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .calls, subtitle: calls.map { "\($0.count) calls" } ?? "", search: $search) {
                Picker("", selection: $missedOnly) {
                    Text("All").tag(false)
                    Text("Missed").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                ExportButton { Panels.saveText(Exporter.callsCSV(filtered), name: "Call History.csv") }.disabled(filtered.isEmpty)
            }
            PaneContainer(items: calls, icon: Pane.calls.icon, emptyTitle: "No Call History") { _ in
                Table(filtered, selection: $selection) {
                    TableColumn("") { call in
                        Image(systemName: call.kind == .outgoing ? "phone.arrow.up.right" : (call.kind == .missed ? "phone.down" : "phone.arrow.down.left"))
                            .foregroundStyle(call.kind == .missed ? Color.red : (call.kind == .outgoing ? Color.blue : Color.green))
                    }
                    .width(24)
                    TableColumn("Contact") { call in
                        Text(call.name.isEmpty ? call.address : call.name).foregroundStyle(call.kind == .missed ? Color.red : Color.primary)
                    }
                    TableColumn("Number") { Text($0.address).foregroundStyle(.secondary) }
                    TableColumn("Direction") { Text($0.kind.rawValue) }.width(80)
                    TableColumn("Service") { Text($0.service) }.width(110)
                    TableColumn("Date") { Text(Fmt.date($0.date)) }.width(160)
                    TableColumn("Duration") { Text($0.duration > 0 ? Fmt.duration($0.duration) : "—") }.width(70)
                    TableColumn("Location") { Text($0.location).foregroundStyle(.secondary) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { calls = await load(backup) { $0.loadCalls() } }
    }
}

@MainActor @Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    var playing: String?
    private var player: AVAudioPlayer?

    func toggle(_ item: AudioItem, backup: Backup) {
        if playing == item.id {
            stop()
            return
        }
        stop()
        Task {
            let url = await Task.detached { backup.localURL(item.domain, item.path, materialize: backup.isEncrypted) }.value
            guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
                NSSound.beep()
                return
            }
            player.delegate = self
            player.play()
            self.player = player
            playing = item.id
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct AudioListView: View {
    let pane: Pane
    let backup: Backup
    let loader: @Sendable (Backup) -> [AudioItem]
    @Environment(AppModel.self) private var model
    @State private var items: [AudioItem]?
    @State private var playback = AudioPlayback()
    @State private var search = ""

    private var filtered: [AudioItem] {
        (items ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, subtitle: items.map { "\($0.count) recordings" } ?? "", search: $search) {
                ExportButton(title: "Export All", action: exportAll).disabled(filtered.isEmpty)
            }
            PaneContainer(items: items, icon: pane.icon, emptyTitle: "No \(pane.title)") { _ in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { item in
                            HStack(spacing: 12) {
                                Button {
                                    playback.toggle(item, backup: backup)
                                } label: {
                                    Image(systemName: playback.playing == item.id ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 28)).foregroundStyle(pane.color)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).fontWeight(.medium)
                                    Text(item.subtitle).font(.caption).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                Text(Fmt.date(item.date)).font(.callout).foregroundStyle(Theme.dim)
                                Text(item.duration > 0 ? Fmt.duration(item.duration) : "").font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
                                Button {
                                    save(item)
                                } label: {
                                    Image(systemName: "square.and.arrow.down")
                                }
                                .buttonStyle(.borderless).help("Save recording…")
                                Button {
                                    airdrop(item)
                                } label: {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                }
                                .buttonStyle(.borderless).help("AirDrop…")
                            }
                            .panel(padding: 10)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .task { items = await load(backup, loader) }
        .onDisappear { playback.stop() }
    }

    private func save(_ item: AudioItem) {
        let name = Exporter.safeName(item.title) + "." + (item.path as NSString).pathExtension
        guard let url = Panels.save(name: name), let entry = backup.entry(item.domain, item.path) else { return }
        do { try backup.extract(entry, to: url) } catch { NSAlert(error: error).runModal() }
    }

    private func airdrop(_ item: AudioItem) {
        let backup = backup
        Task {
            guard let url = await Task.detached(operation: { backup.localURL(item.domain, item.path, materialize: backup.isEncrypted) }).value else {
                NSSound.beep()
                return
            }
            AirDrop.share([url])
        }
    }

    private func exportAll() {
        guard let folder = Panels.chooseFolder() else { return }
        let directory = Exporter.uniqueURL(in: folder, name: pane.title)
        let backup = backup, items = filtered
        model.run("Exporting \(pane.title)", reveal: directory) { _ in
            Exporter.exportAudio(backup, items, to: directory)
            return nil
        }
    }
}

struct NotesView: View {
    let backup: Backup
    @Environment(AppModel.self) private var model
    @State private var notes: [Note]?
    @State private var selection: Int64?
    @State private var bodyText = ""
    @State private var search = ""

    private var selected: Note? { notes?.first { $0.id == selection } }
    private var filtered: [Note] {
        (notes ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.snippet.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .notes, subtitle: notes.map { "\($0.count) notes" } ?? "", search: $search) {
                Menu {
                    Button("Export Selected Note…") {
                        if let note = selected { Panels.saveText("\(note.title)\n\n\(bodyText)\n", name: Exporter.safeName(note.title) + ".txt") }
                    }
                    .disabled(selected == nil)
                    Button("Export All Notes…", action: exportAll)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderedButton).fixedSize().disabled(notes?.isEmpty ?? true)
            }
            PaneContainer(items: notes, icon: Pane.notes.icon, emptyTitle: "No Notes") { _ in
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { note in
                                let active = note.id == selection
                                Button {
                                    selection = note.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 4) {
                                            if note.locked { Image(systemName: "lock.fill").font(.caption) }
                                            Text(note.title).fontWeight(.semibold).lineLimit(1)
                                        }
                                        Text(note.snippet.isEmpty ? " " : note.snippet).font(.caption).opacity(0.7).lineLimit(1)
                                        Text("\(Fmt.short(note.modified)) · \(note.folder)").font(.caption2).opacity(0.55).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: Fmt.isRTL(note.title) ? .trailing : .leading)
                                    .font(.callout)
                                    .foregroundStyle(active ? .black : .white)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(active ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .frame(width: 290)
                    .background(Theme.sidebar.opacity(0.5))
                    if let note = selected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(note.folder) · Created \(Fmt.date(note.created)) · Modified \(Fmt.date(note.modified))")
                                    .font(.caption).foregroundStyle(Theme.dim)
                                Text(bodyText).textSelection(.enabled).natural(bodyText)
                                    .frame(maxWidth: .infinity, alignment: Fmt.isRTL(bodyText) ? .trailing : .leading)
                            }
                            .padding(22)
                        }
                    } else {
                        EmptyState(icon: Pane.notes.icon, title: "Select a Note")
                    }
                }
            }
        }
        .task {
            let loaded = await load(backup) { $0.loadNotes() }
            notes = loaded
            selection = loaded.first?.id
        }
        .task(id: selection) {
            guard let note = selected else { return }
            bodyText = await load(backup) { $0.noteBody(note) }
        }
    }

    private func exportAll() {
        guard let notes, let folder = Panels.chooseFolder() else { return }
        let directory = Exporter.uniqueURL(in: folder, name: "Notes")
        let backup = backup
        model.run("Exporting Notes", reveal: directory) { progress in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, note) in notes.enumerated() {
                if !progress(Double(index) / Double(notes.count), note.title) { throw ExportCancelled() }
                let text = "\(note.title)\n\(note.folder) — \(Fmt.date(note.modified))\n\n\(backup.noteBody(note))\n"
                try text.write(to: Exporter.uniqueURL(in: directory, name: Exporter.safeName(note.title) + ".txt"), atomically: true, encoding: .utf8)
            }
            return nil
        }
    }
}

struct ContactsView: View {
    let backup: Backup
    @State private var contacts: [Contact]?
    @State private var selection: Int64?
    @State private var photo: NSImage?
    @State private var search = ""

    private var selected: Contact? { contacts?.first { $0.id == selection } }
    private var filtered: [Contact] {
        (contacts ?? []).filter { contact in
            search.isEmpty || contact.title.localizedCaseInsensitiveContains(search) || contact.organization.localizedCaseInsensitiveContains(search)
                || contact.phones.contains { $0.value.contains(search) } || contact.emails.contains { $0.value.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .contacts, subtitle: contacts.map { "\($0.count) contacts" } ?? "", search: $search) {
                Menu {
                    Button("Export as vCard…") { Panels.saveText(Exporter.vcard(filtered), name: "Contacts.vcf") }
                    Button("Export as CSV…") {
                        let rows = filtered.map { [$0.first, $0.last, $0.organization, $0.phones.map(\.value).joined(separator: "; "), $0.emails.map(\.value).joined(separator: "; ")] }
                        Panels.saveText(Exporter.csv(["First", "Last", "Organization", "Phones", "Emails"], rows), name: "Contacts.csv")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderedButton).fixedSize().disabled(filtered.isEmpty)
            }
            PaneContainer(items: contacts, icon: Pane.contacts.icon, emptyTitle: "No Contacts") { _ in
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { contact in
                                let active = contact.id == selection
                                Button {
                                    selection = contact.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Avatar(name: contact.title, size: 28)
                                        Text(contact.title).lineLimit(1)
                                        Spacer()
                                    }
                                    .font(.callout)
                                    .foregroundStyle(active ? .black : .white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(active ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .frame(width: 290)
                    .background(Theme.sidebar.opacity(0.5))
                    if let contact = selected { detail(contact) } else { EmptyState(icon: Pane.contacts.icon, title: "Select a Contact") }
                }
            }
        }
        .task {
            let loaded = await load(backup) { $0.contacts() }
            contacts = loaded
            selection = loaded.first?.id
        }
        .task(id: selection) {
            photo = nil
            guard let id = selection else { return }
            let data = await load(backup) { $0.contactImage(id) }
            photo = data.flatMap(NSImage.init(data:))
        }
    }

    private func detail(_ contact: Contact) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Avatar(name: contact.title, size: 88, image: photo)
                VStack(spacing: 3) {
                    Text(contact.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    let role = [contact.jobTitle, contact.displayName == contact.organization ? "" : contact.organization].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !role.isEmpty { Text(role).foregroundStyle(Theme.dim) }
                }
                VStack(spacing: 9) {
                    ForEach(contact.phones, id: \.self) { DetailRow(label: $0.label.isEmpty ? "phone" : $0.label.lowercased(), value: $0.value) }
                    ForEach(contact.emails, id: \.self) { DetailRow(label: $0.label.isEmpty ? "email" : $0.label.lowercased(), value: $0.value) }
                    ForEach(contact.urls, id: \.self) { DetailRow(label: $0.label.isEmpty ? "url" : $0.label.lowercased(), value: $0.value) }
                    ForEach(contact.addresses, id: \.self) { DetailRow(label: $0.label.isEmpty ? "address" : $0.label.lowercased(), value: $0.value) }
                    if let birthday = contact.birthday { DetailRow(label: "birthday", value: Fmt.day.string(from: birthday)) }
                    if !contact.note.isEmpty { DetailRow(label: "note", value: contact.note) }
                }
                .panel()
                .frame(maxWidth: 560)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct CalendarView: View {
    let backup: Backup
    @State private var events: [CalendarEvent]?
    @State private var search = ""
    @State private var selection: Int64?

    private var filtered: [CalendarEvent] {
        (events ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.location.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .calendar, subtitle: events.map { "\($0.count) events" } ?? "", search: $search) {
                ExportButton { Panels.saveText(Exporter.calendarCSV(filtered), name: "Calendar.csv") }.disabled(filtered.isEmpty)
            }
            PaneContainer(items: events, icon: Pane.calendar.icon, emptyTitle: "No Calendar Events") { _ in
                Table(filtered, selection: $selection) {
                    TableColumn("Event") { Text($0.title) }
                    TableColumn("Start") { Text($0.allDay ? Fmt.day.string(from: $0.start ?? .distantPast) : Fmt.date($0.start)) }.width(160)
                    TableColumn("End") { Text($0.allDay ? "All day" : Fmt.date($0.end)) }.width(160)
                    TableColumn("Calendar") { Text($0.calendar).foregroundStyle(.secondary) }.width(130)
                    TableColumn("Location") { Text($0.location).foregroundStyle(.secondary) }
                    TableColumn("Notes") { Text($0.notes).foregroundStyle(.secondary).lineLimit(1) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { events = await load(backup) { $0.loadCalendar() } }
    }
}

struct WebListView: View {
    let pane: Pane
    let backup: Backup
    let loader: @Sendable (Backup) -> [WebItem]
    @State private var items: [WebItem]?
    @State private var search = ""
    @State private var selection = Set<Int64>()

    private var filtered: [WebItem] {
        (items ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, subtitle: items.map { "\($0.count) items" } ?? "", search: $search) {
                ExportButton { Panels.saveText(Exporter.webCSV(filtered), name: "Safari \(pane.title).csv") }.disabled(filtered.isEmpty)
            }
            PaneContainer(items: items, icon: pane.icon, emptyTitle: "No \(pane.title)",
                          emptyMessage: pane == .safariHistory ? "Safari history is only included in encrypted backups." : "This backup doesn't contain any data for this category.") { _ in
                Table(filtered, selection: $selection) {
                    TableColumn("Title") { Text($0.title.isEmpty ? $0.url : $0.title) }
                    TableColumn("URL") { Text($0.url).foregroundStyle(.secondary).lineLimit(1) }
                    TableColumn(pane == .safariHistory ? "Visited" : "Folder") { Text(pane == .safariHistory ? Fmt.date($0.date) : $0.detail) }.width(170)
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: Int64.self) { ids in
                    Button("Open in Browser") { open(ids) }
                    Button("Copy URL") { copyToPasteboard(urls(ids).joined(separator: "\n")) }
                } primaryAction: { open($0) }
            }
        }
        .task { items = await load(backup, loader) }
    }

    private func urls(_ ids: Set<Int64>) -> [String] { filtered.filter { ids.contains($0.id) }.map(\.url) }
    private func open(_ ids: Set<Int64>) {
        for url in urls(ids).prefix(10).compactMap(URL.init(string:)) where ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }
}

struct AppsView: View {
    let backup: Backup
    @State private var apps: [AppItem]?
    @State private var search = ""
    @State private var selection: String?

    private var filtered: [AppItem] {
        (apps ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .apps, subtitle: apps.map { "\($0.count) apps" } ?? "", search: $search) {
                ExportButton { Panels.saveText(Exporter.appsCSV(filtered), name: "Apps.csv") }.disabled(filtered.isEmpty)
            }
            PaneContainer(items: apps, icon: Pane.apps.icon, emptyTitle: "No Apps") { _ in
                Table(filtered, selection: $selection) {
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Bundle ID") { Text($0.bundleID).foregroundStyle(.secondary) }
                    TableColumn("Version") { Text($0.version) }.width(90)
                    TableColumn("Developer") { Text($0.vendor).foregroundStyle(.secondary) }
                    TableColumn("Files in Backup") { Text($0.fileCount > 0 ? "\($0.fileCount)" : "—") }.width(110)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { apps = await load(backup) { $0.loadApps() } }
    }
}
