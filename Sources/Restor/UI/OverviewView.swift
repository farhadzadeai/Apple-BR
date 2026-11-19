import SwiftUI
import AppKit

struct OverviewView: View {
    let backup: Backup
    @Environment(AppModel.self) private var model
    @State private var account: String?
    @State private var slices: [StorageSlice]?
    @State private var hovered: String?
    @State private var copied: String?

    private var totalSize: Int64? { slices.map { $0.reduce(0) { $0 + $1.bytes } } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                categories
                HStack(alignment: .top, spacing: 14) {
                    infoPanel
                    actionsPanel.frame(width: 240)
                }
                storagePanel
            }
            .padding(20)
        }
        .task {
            let backup = backup
            account = await Task.detached { backup.appleAccount() }.value
            slices = await Task.detached { backup.storageBreakdown() }.value
        }
    }

    private var categories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Pane.data + Pane.tools) { pane in
                    Button {
                        model.pane = pane
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: pane.icon).font(.system(size: 19)).foregroundStyle(pane.color)
                                .frame(width: 44, height: 44)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Text(pane.title).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                        .frame(width: 82)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, trailing: String = "") -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).kerning(0.8)
            Spacer()
            Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.bottom, 8)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("DEVICE INFO", trailing: copied.map { "Copied \($0)" } ?? "Click a row to copy")
            ForEach(backup.deviceInfoRows(account: account, size: totalSize), id: \.label) { row in
                HStack(spacing: 16) {
                    Text(row.label)
                    Spacer(minLength: 12)
                    Text(row.value).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(hovered == row.label ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? row.label : (hovered == row.label ? nil : hovered) }
                .onTapGesture {
                    copyToPasteboard(row.value)
                    copied = row.label
                }
            }
        }
        .panel()
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("QUICK ACTIONS")
            action("Export All Data", "square.and.arrow.up.on.square") { model.exportAll() }
            action("Export Backup as Folder", "folder.badge.plus") { model.exportBackupAsFolder() }
            action("Export Device Info", "info.circle") {
                Panels.saveText(Exporter.infoText(backup.deviceInfoRows(account: account, size: totalSize)), name: "\(backup.info.deviceName) Info.txt")
            }
            action("Browse Files", "folder") { model.pane = .files }
            action("Show in Finder", "eye") { NSWorkspace.shared.activateFileViewerSelecting([backup.info.url]) }
            if backup.info.isEncrypted { action("Lock Backup", "lock") { model.lock() } }
            action("Refresh Backups", "arrow.clockwise") { model.refresh() }
        }
        .panel()
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.dim).frame(width: 20)
                Text(title)
                Spacer()
            }
            .font(.callout)
            .padding(.vertical, 7).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("STORAGE", trailing: totalSize.map(Fmt.bytes) ?? "Calculating…")
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if let slices, let total = totalSize, total > 0 {
                        ForEach(slices) { slice in
                            Rectangle().fill(slice.color)
                                .frame(width: max(2, (proxy.size.width - CGFloat(slices.count - 1) * 2) * CGFloat(slice.bytes) / CGFloat(total)))
                        }
                    } else {
                        Rectangle().fill(Theme.raised)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 16)
            HStack(spacing: 18) {
                ForEach(slices ?? []) { slice in
                    HStack(spacing: 6) {
                        Circle().fill(slice.color).frame(width: 8, height: 8)
                        Text(slice.name)
                        Text(Fmt.bytes(slice.bytes)).foregroundStyle(Theme.dim)
                    }
                    .font(.caption)
                }
            }
        }
        .panel()
    }
}
