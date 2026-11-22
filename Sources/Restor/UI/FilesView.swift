import SwiftUI
import AppKit

struct FileNode: Identifiable, Hashable {
    let entry: ManifestEntry
    let size: Int64
    var id: String { entry.fileID }
}

struct FilesView: View {
    let backup: Backup
    @Environment(AppModel.self) private var model
    @State private var domains: [(name: String, count: Int)]?
    @State private var domain: String?
    @State private var tree: [String: [ManifestEntry]] = [:]
    @State private var directory = ""
    @State private var nodes: [FileNode] = []
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var loading = false

    private var filteredDomains: [(name: String, count: Int)] {
        (domains ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .files, subtitle: domains.map { "\($0.count) domains" } ?? "", search: $search) {
                ExportButton(title: selection.isEmpty ? "Export Folder" : "Export Selected", action: export).disabled(domain == nil)
            }
            PaneContainer(items: domains.map { $0.map(\.name) }, icon: Pane.files.icon, emptyTitle: "No Files") { _ in
                HStack(spacing: 0) {
                    domainList.frame(width: 300)
                    VStack(spacing: 0) {
                        breadcrumb
                        if loading { LoadingView() } else { table }
                    }
                }
            }
        }
        .task {
            let backup = backup
            let loaded = await Task.detached { backup.domains() }.value
            domains = loaded
            domain = loaded.first { $0.name == "HomeDomain" }?.name ?? loaded.first?.name
        }
        .task(id: domain) {
            guard let domain else { return }
            let backup = backup
            loading = true
            directory = ""
            selection = []
            let loaded = await Task.detached { () -> [String: [ManifestEntry]] in
                var byPath: [String: ManifestEntry] = [:]
                for entry in backup.entries(domain: domain) where !entry.path.isEmpty {
                    byPath[entry.path] = entry
                }
                for entry in byPath.values {
                    var parent = (entry.path as NSString).deletingLastPathComponent
                    while !parent.isEmpty && byPath[parent] == nil {
                        byPath[parent] = ManifestEntry(fileID: "dir:" + parent, domain: domain, path: parent, flags: 2)
                        parent = (parent as NSString).deletingLastPathComponent
                    }
                }
                var tree: [String: [ManifestEntry]] = [:]
                for entry in byPath.values {
                    tree[(entry.path as NSString).deletingLastPathComponent, default: []].append(entry)
                }
                return tree
            }.value
            guard !Task.isCancelled else { return }
            tree = loaded
            loading = false
            await show("")
        }
    }

    private func show(_ path: String) async {
        let backup = backup
        let children = tree[path] ?? []
        directory = path
        selection = []
        nodes = await Task.detached {
            children.map { FileNode(entry: $0, size: $0.isDirectory ? 0 : backup.diskSize($0)) }
                .sorted { ($0.entry.isDirectory ? 0 : 1, $0.entry.name.lowercased()) < ($1.entry.isDirectory ? 0 : 1, $1.entry.name.lowercased()) }
        }.value
    }

    private var domainList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredDomains, id: \.name) { item in
                    let active = item.name == domain
                    Button {
                        domain = item.name
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.name.hasPrefix("AppDomain") ? "app.dashed" : "internaldrive").frame(width: 18)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("\(item.count)").font(.caption).opacity(0.6)
                        }
                        .font(.callout)
                        .foregroundStyle(active ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(active ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .background(Theme.sidebar.opacity(0.5))
    }

    private var breadcrumb: some View {
        let parts = directory.isEmpty ? [] : directory.components(separatedBy: "/")
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(domain ?? "") { Task { await show("") } }
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.dim)
                    Button(part) { Task { await show(parts[0...index].joined(separator: "/")) } }
                }
            }
            .buttonStyle(.plain).font(.callout.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var table: some View {
        Table(nodes, selection: $selection) {
            TableColumn("Name") { node in
                HStack(spacing: 7) {
                    Image(systemName: node.entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(node.entry.isDirectory ? Theme.accent : Theme.dim).frame(width: 18)
                    Text(node.entry.name)
                }
            }
            TableColumn("Size") { Text($0.entry.isDirectory ? "—" : Fmt.bytes($0.size)).foregroundStyle(.secondary) }.width(90)
            TableColumn("Kind") { Text($0.entry.isDirectory ? "Folder" : ($0.entry.flags == 4 ? "Symlink" : ($0.entry.name as NSString).pathExtension.uppercased())).foregroundStyle(.secondary) }.width(90)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Open") { activate(ids) }
            Button("Export…") {
                selection = ids
                export()
            }
            Button("AirDrop") {
                selection = ids
                airdrop()
            }
            Button("Copy Path") {
                copyToPasteboard(nodes.filter { ids.contains($0.id) }.map { "\($0.entry.domain)/\($0.entry.path)" }.joined(separator: "\n"))
            }
        } primaryAction: { activate($0) }
        .overlay {
            if nodes.isEmpty { EmptyState(icon: "folder", title: "Empty Folder") }
        }
    }

    private func activate(_ ids: Set<String>) {
        guard let node = nodes.first(where: { ids.contains($0.id) }) else { return }
        if node.entry.isDirectory {
            Task { await show(node.entry.path) }
        } else if node.entry.flags == 1 {
            let backup = backup
            Task {
                let url = await Task.detached { backup.localURL(node.entry, materialize: backup.isEncrypted) }.value
                if let url { NSWorkspace.shared.open(url) } else { NSSound.beep() }
            }
        }
    }

    private func airdrop() {
        guard let domain else { return }
        let backup = backup
        let chosen = nodes.filter { selection.contains($0.id) }.map(\.entry)
        let base = directory
        model.airdrop("Preparing AirDrop") { progress in
            var entries: [ManifestEntry] = []
            if chosen.isEmpty {
                entries = base.isEmpty ? backup.entries(domain: domain) : backup.entries(domain: domain, under: base)
            } else {
                for entry in chosen { entries += entry.isDirectory ? backup.entries(domain: domain, under: entry.path) : [entry] }
            }
            let prefix = base.isEmpty ? "" : base + "/"
            let files = entries.filter { $0.flags == 1 && $0.path.hasPrefix(prefix) && !$0.path.components(separatedBy: "/").contains("..") }
            var urls: [URL] = []
            urls.reserveCapacity(files.count)
            for (index, entry) in files.enumerated() {
                if index % 10 == 0, !progress(Double(index) / Double(max(files.count, 1)), entry.name) { throw ExportCancelled() }
                if let url = backup.localURL(entry, materialize: backup.isEncrypted) { urls.append(url) }
            }
            return urls
        }
    }

    private func export() {
        guard let domain, let folder = Panels.chooseFolder() else { return }
        let backup = backup
        let chosen = nodes.filter { selection.contains($0.id) }.map(\.entry)
        let base = directory
        let name = base.isEmpty ? domain : (base as NSString).lastPathComponent
        let root = chosen.isEmpty ? Exporter.uniqueURL(in: folder, name: Exporter.safeName(name)) : folder
        model.run("Exporting Files", reveal: root) { progress in
            var entries: [ManifestEntry] = []
            if chosen.isEmpty {
                entries = base.isEmpty ? backup.entries(domain: domain) : backup.entries(domain: domain, under: base)
            } else {
                for entry in chosen { entries += entry.isDirectory ? backup.entries(domain: domain, under: entry.path) : [entry] }
            }
            let prefix = base.isEmpty ? "" : base + "/"
            let files = entries.filter { $0.flags == 1 && $0.path.hasPrefix(prefix) && !$0.path.components(separatedBy: "/").contains("..") }.map { entry in
                (entry: entry, destination: root.appendingPathComponent(String(entry.path.dropFirst(prefix.count))))
            }
            let failed = try Exporter.exportFiles(backup, files, progress: progress)
            return failed > 0 ? "\(failed) of \(files.count) files could not be exported." : nil
        }
    }
}
