import AppKit
import LockedInClient
import LockedInCore
import SwiftUI

@main
struct LockedInApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = StatusModel()
    @State private var blocklist = BlocklistModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, blocklist: blocklist)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Blocklist", id: "blocklist") {
            BlocklistWindow(blocklist: blocklist)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 460)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running unbundled (swift run) there is no Info.plist LSUIElement; hide the Dock icon anyway.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
