import SwiftUI

/// The "Tips & Commands" cheat-sheet window (MAK-25): a scrollable reference of the
/// gestures, spoken commands, and features that actually ship, each with the real
/// Settings path to enable it. Content is the pure `TipsCatalog` (unit-tested) — this
/// view is a straight render, no logic.
struct TipsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                ForEach(Array(TipsCatalog.groups.enumerated()), id: \.offset) { _, group in
                    groupSection(group)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tips & Commands")
                .font(.title2).bold()
            Text("What you can say and do in OpenWhisp — and where to turn each feature on.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private func groupSection(_ group: TipsCatalog.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.headline)
            Text(group.subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(_ row: TipsCatalog.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.invocation)
                    .font(.system(.body, design: .rounded)).bold()
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.effect)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let path = row.settingsPath {
                Label(path, systemImage: "gearshape")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
