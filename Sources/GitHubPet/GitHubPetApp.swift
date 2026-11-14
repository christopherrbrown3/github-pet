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
        let symbol = model.showsAlertIcon ? "pawprint.fill" : "pawprint"
        // Demo is spelled out in the menu bar itself, not only in accessibility text.
        Group {
            if model.isDemo {
                Text("\(Image(systemName: symbol)) \(PrivacyText.demoLabel.uppercased())")
            } else {
                Image(systemName: symbol)
            }
        }
        .accessibilityLabel(model.statusAccessibilityLabel)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options = LaunchOptions.parse()
    lazy var model = AppModel(options: options)
    private var mascot: MascotWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon even when run straight from `swift run`.
        NSApp.setActivationPolicy(.accessory)
        if let directory = options.snapshotDirectory {
            Task { @MainActor in
                await SnapshotRenderer.run(model: model, directory: directory)
                NSApp.terminate(nil)
            }
            return
        }
        mascot = MascotWindowController(model: model)
    }
}
