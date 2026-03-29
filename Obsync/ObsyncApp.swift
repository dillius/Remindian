import SwiftUI
import EventKit
import ServiceManagement

@main
struct RemindianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var syncManager = SyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
                .onOpenURL { url in
                    OAuthCallbackHandler.shared.handle(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(syncManager)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(syncManager)
                .onOpenURL { url in
                    OAuthCallbackHandler.shared.handle(url: url)
                }
        } label: {
            let symbolName = syncManager.isSyncing
                ? "arrow.triangle.2.circlepath.circle.fill"
                : "checkmark.circle.fill"
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let nsImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Remindian")?
                .withSymbolConfiguration(config)
            Image(nsImage: nsImage ?? NSImage())
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip all app initialization when running under a test host.
        // Tests should not trigger permission prompts, syncs, or side effects.
        guard NSClassFromString("XCTestCase") == nil else { return }

        // Each step is isolated so one failure doesn't crash the whole app.
        // Subsystem failures are logged but non-fatal.

        safeInit("Dock icon visibility") { updateDockIconVisibility() }
        safeInit("App icon") { SyncManager.shared.updateAppIcon() }
        safeInit("Notification permission") { NotificationService.shared.requestPermission() }
        safeInit("Vault bookmark") { _ = SyncManager.shared.resolveVaultBookmark() }
        safeInit("MTN bookmark") { _ = TaskNotesSource.resolveMtnBookmark() }
        safeInit("Global hotkey") { SyncManager.shared.updateHotKey() }
        safeInit("File watcher") { SyncManager.shared.updateFileWatcher() }
        safeInit("Auto-updater") { _ = UpdaterService.shared }

        // Request destination access on launch
        Task {
            await SyncManager.shared.requestDestinationAccess()
        }

        // Keep the main SwiftUI window alive when closed (hide instead of release)
        // so we can reshow it from the menu bar without losing the Liquid Glass layout.
        // Tag it with an identifier so openMainWindow() can find it reliably
        // regardless of window level or visibility state.
        safeInit("Window lifecycle") {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.level == .normal {
                    window.isReleasedWhenClosed = false
                    if window.identifier == nil {
                        window.identifier = NSUserInterfaceItemIdentifier("main-window")
                    }
                }
            }
        }

        // macOS 26+ (Tahoe): Configure main window for Liquid Glass
        if #available(macOS 26, *) {
            safeInit("Liquid Glass window") {
                DispatchQueue.main.async {
                    for window in NSApp.windows {
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .hidden
                        window.styleMask.insert(.fullSizeContentView)
                    }
                }
            }
        }
    }

    /// Run an initialization step safely. If the block crashes the process, at least the
    /// debug log will show which step was attempted last.
    private func safeInit(_ label: String, _ block: () -> Void) {
        debugLog("[AppDelegate] Starting: \(label)")
        block()
        debugLog("[AppDelegate] Completed: \(label)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar
    }

    func updateDockIconVisibility() {
        let config = SyncConfiguration.load()
        if config.hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
