import SwiftUI
import AppKit

enum Theme {
    static let background = Color(red: 0.075, green: 0.094, blue: 0.122)
    static let sidebar = Color(red: 0.055, green: 0.07, blue: 0.094)
    static let panel = Color(red: 0.118, green: 0.145, blue: 0.18)
    static let raised = Color(red: 0.165, green: 0.2, blue: 0.243)
    static let accent = Color(red: 0.98, green: 0.77, blue: 0.2)
    static let dim = Color.white.opacity(0.5)
    static let line = Color.white.opacity(0.07)
}

extension View {
    func panel(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func natural(_ text: String) -> some View {
        multilineTextAlignment(Fmt.isRTL(text) ? .trailing : .leading)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PaneHeader<Trailing: View>: View {
    let pane: Pane
    var subtitle = ""
    var search: Binding<String>?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.icon).font(.title3).foregroundStyle(pane.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title).font(.title3.weight(.semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.dim) }
            }
            Spacer()
            trailing
            if let search { SearchField(text: search).frame(width: 220) }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(pane: Pane, subtitle: String = "", search: Binding<String>? = nil) {
        self.init(pane: pane, subtitle: subtitle, search: search) { EmptyView() }
    }
}

struct ExportButton: View {
    var title = "Export"
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: "square.and.arrow.up") }
            .buttonStyle(.bordered).controlSize(.regular)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(Theme.dim)
            Text(title).font(.title3.weight(.medium))
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingView: View {
    var label = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(label).font(.callout).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 34
    var image: NSImage?

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.filter { $0.first?.isLetter ?? false }
        return letters.joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.raised, Color.white.opacity(0.22)], startPoint: .bottom, endPoint: .top))
            if let image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.8))
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(Theme.dim).frame(width: 110, alignment: .trailing)
            Text(value).textSelection(.enabled).natural(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct PaneContainer<Item, Content: View>: View {
    let items: [Item]?
    let icon: String
    let emptyTitle: String
    var emptyMessage = "This backup doesn't contain any data for this category."
    @ViewBuilder var content: ([Item]) -> Content

    var body: some View {
        if let items {
            if items.isEmpty { EmptyState(icon: icon, title: emptyTitle, message: emptyMessage) } else { content(items) }
        } else {
            LoadingView()
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
