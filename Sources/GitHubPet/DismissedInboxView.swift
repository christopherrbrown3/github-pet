import GitHubPetCore
import SwiftUI

struct DismissedInboxView: View {
    let rows: [DismissedInboxRow]
    let privacy: Bool
    let restore: (String) -> Void
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0

    var body: some View {
        if rows.isEmpty {
            Text("No dismissed items to show.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
                .accessibilityIdentifier("inbox.dismissedEmpty")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        let title = row.title(privacy: privacy)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title).lineLimit(2)
                                Text(row.subtitle(privacy: privacy)).lineLimit(1)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Dismissed \(row.record.dismissedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            Button("Restore") { restore(row.id) }
                                .controlSize(.small)
                                .accessibilityLabel("Restore \(title)")
                                .accessibilityIdentifier("inbox.restore")
                        }
                    }
                }
            }
            .frame(minHeight: InboxView.listHeight(rows: rows.count, textScale: textScale), maxHeight: InboxView.maxListHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dismissed items")
        }
    }
}
