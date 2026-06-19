import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(prefs)
        } label: {
            Image(systemName: state.status.symbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(prefs)
                .frame(width: 560, height: 460)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { Selftest.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--pipetest") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            let prof = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : nil
            CLITest.run(path: path, profileName: prof)
        }
        NSApp.setActivationPolicy(.accessory) // menu-bar only
        AppState.shared.bootstrap()
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.backend.stop()
    }
}
