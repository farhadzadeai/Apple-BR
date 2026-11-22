import SwiftUI
import AppKit

struct ChatView: View {
    let pane: Pane
    let backup: Backup
    let make: @Sendable (Backup) -> ChatSource
    @Environment(AppModel.self) private var model
    @State private var source: ChatSource?
    @State private var conversations: [Conversation]?
    @State private var selection: Int64?
    @State private var messages: [ChatMessage] = []
    @State private var stamps = Set<Int64>()
    @State private var loadingMessages = false
    @State private var search = ""

    private var selected: Conversation? { conversations?.first { $0.id == selection } }
    private var filtered: [Conversation] {
        guard let conversations else { return [] }
        guard !search.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) || $0.snippet.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, subtitle: conversations.map { "\($0.count) conversations" } ?? "", search: $search) {
                Menu {
                    Button("Export Selected Conversation…", action: exportSelected).disabled(selected == nil)
                    Button("Export All Conversations…", action: exportAll)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderedButton).fixedSize()
                .disabled(conversations?.isEmpty ?? true)
            }
            PaneContainer(items: conversations, icon: pane.icon, emptyTitle: "No \(pane.title) Data",
                          emptyMessage: "No \(pane.title) database was found in this backup.") { _ in
                HStack(spacing: 0) {
                    list.frame(width: 300)
                    thread
                }
            }
        }
        .task {
            Diag.log("chat load start pane=\(pane.rawValue)") // TEMP-DIAG
            let started = Date() // TEMP-DIAG
            let backup = backup, make = make
            let loaded = await Task.detached { () -> (ChatSource, [Conversation]) in
                let source = make(backup)
                return (source, source.conversations())
            }.value
            source = loaded.0
            conversations = loaded.1
            selection = loaded.1.first?.id
            Diag.log("chat conversations loaded pane=\(pane.rawValue) n=\(loaded.1.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))") // TEMP-DIAG
        }
        .task(id: selection) {
            guard let source, let conversation = selected else {
                messages = []
                return
            }
            loadingMessages = true
            let loaded = await Task.detached { source.messages(in: conversation) }.value
            guard !Task.isCancelled else { return }
            var stamps = Set<Int64>()
            var previous: Date?
            for message in loaded {
                if let date = message.date, previous == nil || date.timeIntervalSince(previous!) > 900 { stamps.insert(message.id) }
                previous = message.date ?? previous
            }
            self.stamps = stamps
            messages = loaded
            loadingMessages = false
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { conversation in
                    let active = conversation.id == selection
                    Button {
                        selection = conversation.id
                    } label: {
                        HStack(spacing: 10) {
                            Avatar(name: conversation.title)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(conversation.title).fontWeight(.semibold).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(Fmt.short(conversation.lastDate)).font(.caption).opacity(0.7)
                                }
                                Text(conversation.snippet).font(.caption).opacity(0.7).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: Fmt.isRTL(conversation.snippet) ? .trailing : .leading)
                            }
                        }
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
        .background(Theme.sidebar.opacity(0.5))
    }

    @ViewBuilder private var thread: some View {
        if let conversation = selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Avatar(name: conversation.title, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title).font(.headline)
                        Text([conversation.identifier == conversation.title ? "" : conversation.identifier, conversation.service, "\(messages.count) messages"]
                            .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
                Divider().overlay(Theme.line)
                if loadingMessages && messages.isEmpty {
                    LoadingView()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(messages) { message in
                                if stamps.contains(message.id) {
                                    Text(Fmt.date(message.date)).font(.caption2).foregroundStyle(Theme.dim).padding(.top, 10).padding(.bottom, 2)
                                }
                                MessageBubble(backup: backup, message: message, showSender: !message.fromMe && message.sender != conversation.title, tint: pane.color)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .id(conversation.id)
                }
            }
        } else {
            EmptyState(icon: pane.icon, title: "Select a Conversation")
        }
    }

    private func exportSelected() {
        guard let conversation = selected else { return }
        Panels.saveText(Exporter.transcript(conversation, messages), name: Exporter.safeName(conversation.title) + ".txt")
    }

    private func exportAll() {
        guard let source, let folder = Panels.chooseFolder() else { return }
        let directory = Exporter.uniqueURL(in: folder, name: pane.title)
        model.run("Exporting \(pane.title)", reveal: directory) { progress in
            try Exporter.exportChats(source, to: directory, progress: progress, range: 0...1)
            return nil
        }
    }
}

struct MessageBubble: View {
    let backup: Backup
    let message: ChatMessage
    let showSender: Bool
    let tint: Color

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 80) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                if showSender, !message.sender.isEmpty {
                    Text(message.sender).font(.caption2).foregroundStyle(Theme.dim).padding(.leading, 6)
                }
                ForEach(message.attachments, id: \.self) { AttachmentView(backup: backup, attachment: $0) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .natural(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(message.fromMe ? tint.opacity(0.55) : Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(maxWidth: 520, alignment: message.fromMe ? .trailing : .leading)
            if !message.fromMe { Spacer(minLength: 80) }
        }
        .help(Fmt.date(message.date) + (message.readDate.map { " — Read \(Fmt.date($0))" } ?? ""))
    }
}

struct AttachmentView: View {
    let backup: Backup
    let attachment: ChatAttachment
    @State private var image: NSImage?

    var body: some View {
        Button(action: open) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Label(attachment.name, systemImage: attachment.isVideo ? "video" : (attachment.isImage ? "photo" : "paperclip"))
                    .font(.callout).lineLimit(1)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("AirDrop") { airdrop() }
            Button("Save As…") { save() }
        }
        .task(id: attachment) {
            guard attachment.isImage || attachment.isVideo else { return }
            image = await backup.thumbnails.image(domain: attachment.domain, path: attachment.path, maxPixel: 480)
        }
    }

    private func airdrop() {
        let backup = backup
        Task {
            guard let url = await Task.detached(operation: { backup.localURL(attachment.domain, attachment.path, materialize: backup.isEncrypted) }).value else {
                NSSound.beep()
                return
            }
            AirDrop.share([url])
        }
    }

    private func save() {
        guard let destination = Panels.save(name: attachment.name) else { return }
        let backup = backup
        Task {
            guard let url = await Task.detached(operation: { backup.localURL(attachment.domain, attachment.path, materialize: backup.isEncrypted) }).value else {
                NSSound.beep()
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func open() {
        let backup = backup
        Task {
            guard let url = await Task.detached(operation: { backup.localURL(attachment.domain, attachment.path, materialize: backup.isEncrypted) }).value else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
}
