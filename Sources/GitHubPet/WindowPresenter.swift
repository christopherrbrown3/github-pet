import AppKit
import SwiftUI

/// Owns the Inbox and Settings windows so both the menu bar and the mascot can open them.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()

    private var inboxWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showInbox(model: AppModel) {
        if inboxWindow == nil {
            inboxWindow = makeWindow(title: "GitHub Pet Inbox",
                                     content: InboxView(model: model, showsWindowButton: false),
                                     identifier: "inbox")
        }
        present(inboxWindow)
    }

    func showSettings(model: AppModel) {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "GitHub Pet Settings", content: SettingsView(model: model),
                                        identifier: "settings")
        }
        present(settingsWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content, identifier: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("GitHubPet.\(identifier)")
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // An autosaved frame may be smaller than the content needs (e.g. one saved while a
        // window opened collapsed); never present a window that can't show its controls.
        if let content = window.contentViewController?.view {
            let needed = content.fittingSize
            let current = window.contentLayoutRect.size
            if current.width < needed.width || current.height < needed.height {
                window.setContentSize(NSSize(width: max(current.width, needed.width),
                                             height: max(current.height, needed.height)))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
