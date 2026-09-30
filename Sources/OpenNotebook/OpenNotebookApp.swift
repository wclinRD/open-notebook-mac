import SwiftUI

@main
struct OpenNotebookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var serviceManager = ServiceManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView(serviceManager: serviceManager)
                .environmentObject(serviceManager)
                .task {
                    await serviceManager.startAll(from: ServiceManager.bundledResources)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Reload") {
                    NotificationCenter.default.post(name: .openNotebookReloadWebView, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Restart Services") {
                    Task {
                        await ServiceManager.shared.restart(from: ServiceManager.bundledResources)
                    }
                }

                Divider()

                Button("Quit OpenNotebook") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let openNotebookReloadWebView = Notification.Name("OpenNotebook.reloadWebView")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quitting has to wait for the services to actually die.
    ///
    /// Returning `.terminateLater` keeps the process alive after this method
    /// returns, so the async `stopAll()` can finish sending SIGTERM and escalating
    /// to SIGKILL. Tearing down from a detached `Task` inside
    /// `applicationWillTerminate` instead would let the app exit mid-teardown and
    /// leave SurrealDB holding the database lock.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await ServiceManager.shared.stopAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
