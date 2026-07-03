import SwiftUI

// Shared building blocks for the Settings panes (redesign spec §8). One visual
// language for the same job everywhere: model rows, callouts, permission rows,
// test results, selectable option rows, and the token field.

// MARK: - Callout

/// Inline notice with a tint, a message, and an optional action button.
/// Replaces the ad-hoc orange `Text`s — a warning without a next step is only
/// half a warning.
struct SettingsCallout: View {
    enum Tone {
        case info, warning, error

        var color: Color {
            switch self {
            case .info:    return .accentColor
            case .warning: return .orange
            case .error:   return .red
            }
        }

        var symbol: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            }
        }
    }

    let tone: Tone
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?

    init(_ tone: Tone, _ message: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.tone = tone
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.symbol)
                .foregroundColor(tone.color)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Selectable option row

/// A radio-style row with a title, optional subtitle, and optional trailing
/// badge — used where a bare menu picker can't carry the explanation (engine
/// choice, output mode, insertion method). Supports disabled-with-reason so
/// options can be shown-disabled instead of hidden (spec principle 4).
struct SelectableRow: View {
    let title: String
    var subtitle: String?
    var badge: String?
    let isSelected: Bool
    var isEnabled: Bool = true
    let onSelect: () -> Void

    var body: some View {
        Button(action: { if isEnabled { onSelect() } }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Model row

/// One installed/installable model: `[selection] Name ·size· [accessory]`, with
/// a Remove button for installed models. Used by whisper.cpp models, WhisperKit
/// models, and the bundled LLM — today's three different UIs for one job.
struct ModelRow: View {
    enum Accessory {
        /// Not on disk — offer a download (or select-to-download).
        case download
        /// Download in flight (nil = indeterminate).
        case downloading(Double?)
        /// On disk, not the active model.
        case installed
        /// On disk and currently in use.
        case inUse
        /// No state to show (e.g. remote/cloud models).
        case none
    }

    let title: String
    var subtitle: String?
    var sizeText: String?
    let isSelected: Bool
    let accessory: Accessory
    var onSelect: (() -> Void)?
    var onDownload: (() -> Void)?
    var downloadDisabled: Bool = false
    var onDelete: (() -> Void)?
    var deleteDisabled: Bool = false
    var deleteDisabledReason: String?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let onSelect {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "\(title), selected" : "Select \(title)")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let sizeText {
                        Text(sizeText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            accessoryView

            if let onDelete, showsDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(deleteDisabled)
                .help(deleteDisabled
                      ? (deleteDisabledReason ?? "This model can't be removed right now")
                      : "Remove this model from disk")
                .opacity(hovering || deleteDisabled ? 1 : 0)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect?() }
    }

    private var showsDelete: Bool {
        switch accessory {
        case .installed, .inUse: return true
        default: return false
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .download:
            if let onDownload {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(downloadDisabled)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.secondary)
                    .help("Downloads when selected")
            }
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 100)
                    .accessibilityLabel("Downloading \(title), \(Int(progress * 100)) percent")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Downloading \(title)")
            }
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .inUse:
            Text("● In use")
                .font(.caption.weight(.medium))
                .foregroundColor(.accentColor)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Permission row

/// Status dot + status *word* (never color alone) + one trailing action.
struct PermissionRow: View {
    let name: String
    let statusLabel: String
    var actionLabel: String?
    var action: (() -> Void)?

    private var granted: Bool { statusLabel == "Granted" }

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(granted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(statusLabel)
                    .foregroundColor(granted ? .green : .orange)
            }
            if let actionLabel, let action, !granted {
                Button(actionLabel, action: action)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(statusLabel)")
    }
}

// MARK: - Test result line

/// Persistent inline result under a Test button: symbol + summary + how long
/// ago — instead of a transient status string that vanishes into memory.
struct TestResultLine: View {
    let text: String
    let isGood: Bool
    var timestamp: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "info.circle")
                .foregroundColor(isGood ? .green : .secondary)
            Text(text)
                .font(.caption)
                .foregroundColor(isGood ? .green : .secondary)
            if let timestamp {
                Text("· \(timestamp.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Token field

/// Editable chip list for the vocabulary bias terms — commas are an
/// implementation detail users shouldn't manage. Enter (or comma) commits the
/// draft as a chip; each chip has a remove button.
struct TokenField: View {
    @Binding var tokens: [String]
    var placeholder: String
    var isEnabled: Bool = true

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tokens.isEmpty {
                WrapLayout(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: 3) {
                            Text(token).font(.caption)
                            Button {
                                tokens.removeAll { $0 == token }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .imageScale(.small)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(token)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }

            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitDraft)
                .onChange(of: draft) {
                    // A typed/pasted comma commits everything before it.
                    if draft.contains(",") { commitDraft() }
                }
                .onDisappear(perform: commitDraft)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func commitDraft() {
        let parts = draft.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        draft = ""
        guard !parts.isEmpty else { return }
        for part in parts where !tokens.contains(part) {
            tokens.append(part)
        }
    }
}

/// Minimal flow layout: lays children left-to-right, wrapping to a new line
/// when the row is full. Backs the TokenField chips.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews: subviews, maxWidth: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews: subviews, maxWidth: bounds.width).positions
        for (subview, position) in zip(subviews, positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Footnote

/// Consistent caption text used as an explanatory footnote inside sections.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A toggle with a caption subtitle underneath — the standard control+why row.
struct SubtitledToggle: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
