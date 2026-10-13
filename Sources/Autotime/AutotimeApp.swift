import SwiftUI
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.prompt()
        }
        Tracker.shared.start()
        Limits.shared.start()
        _ = Updater.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        Tracker.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Limit reminders show even while Autotime's window is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct AutotimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = DayModel()
    @StateObject private var tracker = Tracker.shared

    var body: some Scene {
        Window("Autotime", id: "main") {
            ContentView()
                .environment(model)
                .environmentObject(tracker)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            CommandGroup(after: .newItem) {
                Button("Export…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Previous Day") { model.shift(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Day") { model.shift(1) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Go to Today") { model.goToToday() }.keyboardShortcut("t", modifiers: [.command])
                Divider()
                Button("Zoom In Timeline") { model.hourHeight = min(600, model.hourHeight * 1.25) }.keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out Timeline") { model.hourHeight = max(60, model.hourHeight / 1.25) }.keyboardShortcut("-", modifiers: [.command])
                Divider()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(tracker)
        } label: {
            Image(systemName: tracker.isPaused ? "pause.circle" : "clock")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(tracker)
        }
    }
}
