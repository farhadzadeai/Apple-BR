import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SidebarView().frame(width: 236)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .task { model.refresh() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                    guard let url else { return }
                    Task { @MainActor in model.handleDrop([url]) }
                }
            }
            return true
        }
        .sheet(item: $model.job) { JobView(job: $0) }
        .alert("Restor", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let backup = model.backup {
            PaneView(backup: backup, pane: model.pane)
                .id(backup.cacheDir.lastPathComponent + model.pane.rawValue)
                .padding(.top, 8)
        } else if let info = model.selected {
            if info.isEncrypted {
                PasswordView(info: info)
            } else if let error = model.openError {
                EmptyState(icon: "exclamationmark.triangle", title: "Couldn't Open Backup", message: error)
            } else {
                LoadingView(label: "Opening backup…")
            }
        } else {
            WelcomeView()
        }
    }
}

extension Job: Identifiable {}

struct PaneView: View {
    let backup: Backup
    let pane: Pane

    var body: some View {
        switch pane {
        case .overview: OverviewView(backup: backup)
        case .photos: PhotosView(backup: backup)
        case .messages: ChatView(pane: pane, backup: backup) { SMSSource(backup: $0) }
        case .whatsapp: ChatView(pane: pane, backup: backup) { WhatsAppSource(backup: $0, business: false) }
        case .whatsappBusiness: ChatView(pane: pane, backup: backup) { WhatsAppSource(backup: $0, business: true) }
        case .calls: CallsView(backup: backup)
        case .voicemail: AudioListView(pane: pane, backup: backup) { $0.loadVoicemail() }
        case .voiceMemos: AudioListView(pane: pane, backup: backup) { $0.loadVoiceMemos() }
        case .notes: NotesView(backup: backup)
        case .contacts: ContactsView(backup: backup)
        case .calendar: CalendarView(backup: backup)
        case .safariHistory: WebListView(pane: pane, backup: backup) { $0.loadSafariHistory() }
        case .bookmarks: WebListView(pane: pane, backup: backup) { $0.loadBookmarks(readingList: false) }
        case .readingList: WebListView(pane: pane, backup: backup) { $0.loadBookmarks(readingList: true) }
        case .apps: AppsView(backup: backup)
        case .files: FilesView(backup: backup)
        }
    }
}

struct JobView: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job.title).font(.headline)
            ProgressView(value: min(max(job.fraction, 0), 1))
            Text(job.detail.isEmpty ? "Preparing…" : job.detail).font(.caption).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel") { job.flag.cancel() }
            }
        }
        .padding(22)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: model.accessDenied ? "lock.shield" : "iphone.gen3")
                .font(.system(size: 54, weight: .light)).foregroundStyle(Theme.accent)
            Text(model.accessDenied ? "Full Disk Access Required" : "No iPhone Backups Found").font(.title2.weight(.semibold))
            Text(model.accessDenied
                 ? "macOS protects the folder where iPhone backups are stored. You can either grant Restor Full Disk Access in System Settings, or choose the backup folder yourself — macOS will ask for your permission when you pick it."
                 : "Back up your iPhone with Finder, then drag the .backup onto this window, choose its location, or open the default backup folder.")
                .foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                if model.accessDenied {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
                Button("Choose Backup Folder…") { model.chooseFolder() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                Button("Refresh") { model.refresh() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PasswordView: View {
    let info: BackupInfo
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
            Text("Encrypted Backup").font(.title2.weight(.semibold))
            Text("Enter the backup password for “\(info.deviceName)”. The password is only used on this Mac to decrypt the backup.")
                .foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 400)
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder).controlSize(.large).frame(width: 300)
                .focused($focused)
                .onSubmit(unlock)
                .disabled(model.isOpening)
            if model.isOpening {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Deriving keys and decrypting… this can take a few seconds.").font(.callout).foregroundStyle(Theme.dim)
                }
            } else if let error = model.passwordError {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout)
            }
            Button("Unlock", action: unlock)
                .buttonStyle(.borderedProminent).foregroundStyle(.black).controlSize(.large)
                .disabled(password.isEmpty || model.isOpening)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        model.open(password: password)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            backupMenu.padding(.top, 44).padding(.horizontal, 12)
            if let info = model.selected {
                DeviceCard(info: info, unlocked: model.backup != nil).padding(.vertical, 18)
            }
            List(selection: Binding<Pane?>(
                get: { model.pane },
                set: { if let pane = $0 { model.pane = pane } }
            )) {
                Section {
                    navRow(.overview)
                }
                Section("Data") {
                    ForEach(Pane.data) { navRow($0) }
                }
                Section("Tools") {
                    ForEach(Pane.tools) { navRow($0) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .opacity(model.backup == nil ? 0.35 : 1)
            .disabled(model.backup == nil)

            Divider().opacity(0.4)
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "about")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.dim).frame(width: 20)
                    Text("About Farhadzadeai").foregroundStyle(Theme.dim)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private var backupMenu: some View {
        Menu {
            ForEach(model.backups) { info in
                Button {
                    model.select(info)
                } label: {
                    Text("\(info.deviceName) — \(Fmt.date(info.date))" + (info.isEncrypted ? " 🔒" : ""))
                }
            }
            if !model.backups.isEmpty { Divider() }
            Button("Open Backup Folder…") { model.chooseFolder() }
            Button("Refresh") { model.refresh() }
        } label: {
            HStack {
                Image(systemName: "externaldrive.fill")
                Text(model.backups.isEmpty ? "No Backups" : "\(model.backups.count) Backup\(model.backups.count == 1 ? "" : "s")")
                Spacer()
            }
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Choose a backup folder anywhere on this Mac, or drag a .backup onto the window")
    }

    private func navRow(_ pane: Pane) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pane.icon).foregroundStyle(pane.color).frame(width: 20)
            Text(pane.title)
        }
        .tag(pane)
    }
}

struct DeviceCard: View {
    let info: BackupInfo
    let unlocked: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.raised, Theme.panel], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
                Capsule().fill(Color.black.opacity(0.55)).frame(width: 24, height: 7).padding(.top, 7)
                Image(systemName: info.isEncrypted ? (unlocked ? "lock.open.fill" : "lock.fill") : "apple.logo")
                    .font(.title3).foregroundStyle(.white.opacity(0.35)).frame(maxHeight: .infinity)
            }
            .frame(width: 66, height: 132)
            Text(info.deviceName).font(.headline).lineLimit(1)
            Text("\(info.productName) · iOS \(info.osVersion)").font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            Text(Fmt.date(info.date)).font(.caption2).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}
