import AppKit
import GitHubPetCore
import SwiftUI

@main
struct GitHubPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            InboxView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.showsAlertIcon ? "pawprint.fill" : "pawprint")
            .accessibilityLabel(model.showsAlertIcon ? "GitHub Pet, needs attention" : "GitHub Pet")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(options: LaunchOptions.parse())
    private var mascot: MascotWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon even when run straight from `swift run`.
        NSApp.setActivationPolicy(.accessory)
        mascot = MascotWindowController(model: model)
    }
}
