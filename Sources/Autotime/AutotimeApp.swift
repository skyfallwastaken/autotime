import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.prompt()
        }
        Tracker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Tracker.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct AutotimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DayModel()
    @StateObject private var tracker = Tracker.shared

    var body: some Scene {
        Window("Autotime", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(tracker)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
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
