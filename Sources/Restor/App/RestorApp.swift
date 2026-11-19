import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Backup.cacheRoot)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Backup.cacheRoot)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RestorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Restor", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        Window("About Restor", id: "about") {
            AboutView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 360)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Backup Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Refresh Backups") { model.refresh() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
        }
    }
}
