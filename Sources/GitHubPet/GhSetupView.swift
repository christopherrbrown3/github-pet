import AppKit
import GitHubPetCore
import SwiftUI

/// "Get GitHub CLI" / "How to sign in" links for the gh-missing and signed-out states (#52).
/// Renders nothing for any other state. Links open in the browser via `Link`; the copy button
/// only writes to the pasteboard.
struct GhSetupView: View {
    let state: DataState

    var body: some View {
        let links = GhSetup.links(for: state)
        if !links.isEmpty {
            HStack(spacing: 12) {
                ForEach(links, id: \.self) { link in
                    Link(link.title, destination: link.url)
                        .accessibilityHint(link.accessibilityHint)
                        .accessibilityIdentifier("ghsetup.\(link == .getCLI ? "get" : "signin")")
                }
                if let command = GhSetup.copyableCommand(for: state) {
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Copy command: \(command)")
                    .accessibilityIdentifier("ghsetup.copy")
                }
            }
            .font(.caption)
        }
    }
}
