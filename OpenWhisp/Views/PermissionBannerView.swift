import SwiftUI

// MARK: - Permission Banner

/// Gentle, dismissible banners shown when a needed permission is missing —
/// typically after a reinstall, when macOS silently revokes the Accessibility
/// grant while the persisted onboarding flag still says "all set up".
///
/// Renders one card per missing permission from
/// `appState.missingPermissionBanners` (refreshed on launch and on every
/// app-became-active, so granting the permission in System Settings and
/// returning makes the banner disappear on its own). Deliberately NOT the full
/// onboarding wizard: one line of consequence, one deep-link button, one
/// dismiss button.
struct PermissionBannerStack: View {

    @ObservedObject var appState: AppState

    var body: some View {
        // Empty when nothing is missing — safe to embed unconditionally.
        VStack(spacing: 8) {
            ForEach(appState.missingPermissionBanners, id: \.self) { permission in
                PermissionBannerCard(
                    permission: permission,
                    openSettings: { appState.openSettings(for: permission) },
                    dismiss: { appState.dismissPermissionBanner(permission) }
                )
            }
        }
    }
}

private struct PermissionBannerCard: View {

    let permission: PermissionBannerPolicy.Permission
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.bannerTitle)
                    .font(.callout.weight(.semibold))
                Text(permission.bannerMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(permission.bannerButtonTitle, action: openSettings)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide for now")
            .accessibilityLabel("Dismiss \(permission.bannerTitle) banner")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}
