import SwiftUI
import AppKit

enum AppInfo {
    static let github = URL(string: "https://github.com/MFarhadzade/restor")!
    static let email = URL(string: "mailto:en.farhadzadeh@gmail.com")!
    static let tagline = "Browse, search and export everything inside your iPhone backups — photos, messages, contacts, calls, notes, Safari data, apps and files."
}

struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Restor") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Restor").font(.title2.weight(.bold))
            Text(AppInfo.tagline)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
            Text("Version \(version)").font(.caption).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 4)
            HStack(spacing: 20) {
                Link(destination: AppInfo.github) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.email) {
                    Label("Email", systemImage: "envelope")
                }
            }
            .font(.callout)
            Text("Made with SwiftUI · Works entirely on this Mac")
                .font(.caption2).foregroundStyle(.quaternary)
        }
        .padding(28)
        .frame(width: 400)
    }
}
