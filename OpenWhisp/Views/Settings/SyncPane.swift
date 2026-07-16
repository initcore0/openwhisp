import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Pair iPhone — the Mac side of P2P sync (MAK-51 WP6). Shows a QR encoding the
/// pairing payload (peer id + display name + a freshly-minted 32-byte TLS-PSK +
/// the Bonjour service instance) for the phone's camera to scan, and lists paired
/// devices with an unpair action (= PSK destruction + dropped connections).
///
/// Nothing leaves the devices: discovery is Bonjour on the LAN, the link is TLS 1.3
/// with the pre-shared key from this QR, and unpairing destroys the key.
struct SyncPane: View {
    @ObservedObject var appState: AppState

    @State private var showingPairSheet = false

    var body: some View {
        Form {
            introSection
            devicesSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPairSheet, onDismiss: { appState.endPairing() }) {
            PairSheet(appState: appState, isPresented: $showingPairSheet)
        }
        // Belt-and-braces exit: closing the Settings WINDOW while the sheet is up
        // doesn't reliably fire the sheet's onDismiss on macOS, which would leave
        // pairing mode (and the LAN listener + staged PSK) stuck on until app
        // restart. endPairing is idempotent, so the doubled call is harmless.
        .onDisappear { appState.endPairing() }
    }

    // MARK: Intro

    private var introSection: some View {
        Section {
            Text("Sync your vocabulary, per-app profiles, modes, and dictation history with a paired iPhone over your local network. Nothing leaves your devices — discovery is Bonjour on your LAN and the link is TLS with a key you pair by QR.")
                .font(.callout)
                .foregroundColor(.secondary)

            Button {
                appState.beginPairing()
                showingPairSheet = true
            } label: {
                Label("Pair iPhone…", systemImage: "qrcode")
            }
        } header: {
            Text("Sync")
        }
    }

    // MARK: Paired devices

    private var devicesSection: some View {
        Section {
            if appState.syncPairedPeers.isEmpty {
                Text("No devices paired yet.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(appState.syncPairedPeers) { peer in
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                            Text("Paired \(peer.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Unpair") {
                            appState.unpairDevice(peer.id)
                        }
                        .help("Destroy this device's key and stop syncing with it.")
                    }
                }
            }
        } header: {
            Text("Paired Devices")
        }
    }
}

/// The pairing sheet: renders the current QR payload big enough to scan and a
/// short instruction. Closing the sheet leaves pairing mode.
private struct PairSheet: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone")
                .font(.title2).bold()

            Text("Open OpenWhisp on your iPhone, tap Pair, and scan this code. It carries a one-time key that stays on your devices.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                ProgressView()
                    .frame(width: 240, height: 240)
            }

            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
    }

    /// The QR NSImage for the current pending payload, or nil if none / encode
    /// failed. Built with the built-in CIQRCodeGenerator — no third-party deps.
    private var qrImage: NSImage? {
        guard let payload = appState.pendingPairingPayload,
              let data = try? payload.qrData() else { return nil }
        return SyncPane.makeQR(from: data)
    }
}

extension SyncPane {
    /// Render `data` as a QR code NSImage using CoreImage's built-in generator.
    /// Scaled up (nearest-neighbor by the caller's `.interpolation(.none)`) so the
    /// small native QR bitmap stays crisp.
    static func makeQR(from data: Data) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = output.transformed(by: scale)
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
