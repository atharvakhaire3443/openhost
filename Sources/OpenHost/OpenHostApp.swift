import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct OpenHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var registry = ModelRegistry.shared

    var body: some Scene {
        WindowGroup("OpenHost") {
            RootView()
                .environmentObject(registry)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
